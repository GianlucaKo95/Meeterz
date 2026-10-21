import Foundation
import UIKit
import Combine
import CarPlay
import CoreLocation
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit

/// CarPlay-Szene. Wird über Info.plist (UIApplicationSceneManifest) eingebunden.
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        MainActor.assumeIsolated {
            CarPlayController.shared.connect(scene: templateApplicationScene, interfaceController: interfaceController, window: window)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        MainActor.assumeIsolated {
            CarPlayController.shared.disconnect(scene: templateApplicationScene, interfaceController: interfaceController, window: window)
        }
    }
}

/// Karte mit Freunden, Navigation (über Mapbox CarPlayManager), Freundesliste als Ziele.
@MainActor
final class CarPlayController: NSObject {
    static let shared = CarPlayController()

    private(set) var isConnected = false
    private var friendsVisible = true
    private var browseOverlay: FriendOverlay?
    private var navigationOverlay: FriendOverlay?
    private var shownInvites = Set<UUID>()
    private var searchTask: Task<Void, Never>?
    private var searchCompletion: (([CPListItem]) -> Void)?
    /// Apple-Flyover-Karte über der Mapbox-Karte (abschaltbar in den iPhone-Einstellungen)
    private var flyover: CarPlayFlyoverMirror?
    private var browseRecenter: Task<Void, Never>?
    private var navRecenter: Task<Void, Never>?
    private var threeDMapButton: CPMapButton?
    /// Meldet, ob das Auto Tastatur oder Listen gerade sperrt (Diagnose für die Suche)
    private var session: CPSessionConfiguration?
    /// Mit +/− gewählter Zoom während der Fahrt (nil = Mapbox rahmt automatisch); gilt bis zum Ende der Fahrt
    private var navZoom: Double?
    /// Fahrer hat die Routenübersicht gewählt – bleibt, auch wenn er darin die Karte verschiebt
    private var overviewChosen = false
    /// Tempowarnung (siehe CarPlayExtras.swift)
    var speedTimer: Timer?
    /// Offene Frage „schnellere Route?“ – wird genau einmal beantwortet
    var fasterRouteAnswer: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    /// Wann zuletzt die Ankunft eines Freundes am selben Ziel gemeldet wurde (je Freund)
    var friendArrivalAnnounced: [UUID: (eta: Date, at: Date)] = [:]

    // MARK: 3D und Kamera

    /// 3D (geneigte Karte) auf CarPlay; Standard an
    private var threeD: Bool {
        get { UserDefaults.standard.object(forKey: "carplay.3d") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "carplay.3d") }
    }

    private static func textImage(_ text: String) -> UIImage {
        let size = CGSize(width: 44, height: 44)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .heavy),
                .foregroundColor: UIColor.black,
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let box = str.size()
            str.draw(at: CGPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// Neigung für 3D. MapKit (Flyover) übernimmt sie 1:1 von der Mapbox-Kamera.
    private static let tilt3D: Double = 65

    /// Zoom außerhalb der Fahrt (mit +/− gewählt, bleibt gespeichert)
    private var browseZoom: Double {
        get { UserDefaults.standard.object(forKey: "carplay.zoom") as? Double ?? 16.5 }
        set { UserDefaults.standard.set(newValue, forKey: "carplay.zoom") }
    }

    private var browseMap: NavigationMapView? { manager.carPlayMapViewController?.navigationMapView }
    private var navMap: NavigationMapView? { manager.carPlayNavigationViewController?.navigationMapView }

    /// Stellt Neigung und Zoom der Folgekamera ein.
    ///
    /// Ursache für „3D tut nichts“ und „Zoom springt zurück“: Ohne Route rechnet Mapbox die Folgekamera bei jedem
    /// Standort-Update neu – Neigung immer 0° und Zoom fest aus 1700 m Höhe; `defaultPitch` gilt nur mit Route.
    /// Darum außerhalb der Fahrt Neigung und Zoom selbst vorgeben und Mapbox das Überschreiben verbieten.
    private func configureCamera(_ navigationMapView: NavigationMapView?, navigating: Bool) {
        guard let camera = navigationMapView?.navigationCamera,
              let source = camera.viewportDataSource as? CarPlayViewportDataSource else { return }
        let pitch = threeD ? Self.tilt3D : 0
        var options = source.options
        var current = source.currentNavigationCameraOptions
        options.followingCameraOptions.defaultPitch = pitch
        if navigating {
            // Mit Route: Mapbox neigt (flacher vor Abbiegungen) und rahmt den Zoom – außer der Fahrer hat selbst gezoomt
            options.followingCameraOptions.pitchUpdatesAllowed = true
            options.followingCameraOptions.zoomUpdatesAllowed = navZoom == nil
            if let navZoom { current.followingCamera.zoom = navZoom }
        } else {
            options.followingCameraOptions.pitchUpdatesAllowed = false
            options.followingCameraOptions.zoomUpdatesAllowed = false
            current.followingCamera.pitch = pitch
            current.followingCamera.zoom = browseZoom
        }
        source.options = options
        source.currentNavigationCameraOptions = current   // folgt die Kamera, übernimmt sie das sofort
        if camera.currentCameraState != .following { camera.update(cameraState: .following) }
    }

    private func toggleThreeD() {
        threeD.toggle()
        configureCamera(browseMap, navigating: false)
        configureCamera(navMap, navigating: true)
        threeDMapButton?.image = Self.textImage(threeD ? "2D" : "3D")
    }

    /// +/−: ändert den Zoom der Folgekamera statt die Kamera anzuhalten – so springt nichts zurück
    private func zoom(by delta: Double) {
        if manager.currentActivity == .navigating, let map = navMap {
            overviewChosen = false
            refreshFriends()
            let now = navZoom ?? map.mapView.mapboxMap?.cameraState.zoom ?? 16
            navZoom = min(max(now + delta, 10), 19)
            configureCamera(map, navigating: true)
        } else {
            browseZoom = min(max(browseZoom + delta, 10), 19)
            configureCamera(browseMap, navigating: false)
        }
    }

    /// Die vier Kartenknöpfe (CarPlay erlaubt höchstens vier): Freunde, 2D/3D, +, −.
    /// Zentrieren braucht es nicht – die Karte kehrt nach 4 s von selbst zum Standort zurück.
    private func mapButtons() -> [CPMapButton] {
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let three = CPMapButton { [weak self] _ in self?.toggleThreeD() }
        three.image = Self.textImage(threeD ? "2D" : "3D")
        threeDMapButton = three
        let plus = CPMapButton { [weak self] _ in self?.zoom(by: 1) }
        plus.image = UIImage(systemName: "plus", withConfiguration: config)
        let minus = CPMapButton { [weak self] _ in self?.zoom(by: -1) }
        minus.image = UIImage(systemName: "minus", withConfiguration: config)
        return [friendsButton(), three, plus, minus]
    }

    /// Während der Fahrt: Übersicht statt Freunde-Knopf (Freunde-Einstellung gilt weiter, in der Übersicht ausgeblendet)
    private func navigationMapButtons() -> [CPMapButton] {
        var buttons = mapButtons()
        let overview = CPMapButton { [weak self] _ in
            guard let self, let camera = navMap?.navigationCamera else { return }
            overviewChosen.toggle()
            camera.update(cameraState: overviewChosen ? .overview : .following)
            refreshFriends()
        }
        overview.image = UIImage(systemName: "point.topleft.down.to.point.bottomright.curvepath",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        buttons[0] = overview
        return buttons
    }

    /// Kehrt nach 4 s zum Standort zurück, wenn man die Karte von Hand weggeschoben hat.
    /// Nur dann: In Routenvorschau und Routenübersicht bleibt die Kamera, wo sie ist.
    private func startAutoRecenter(_ navigationMapView: NavigationMapView) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak navigationMapView] in
            var idle = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let camera = navigationMapView?.navigationCamera else { return }
                let activity = manager.currentActivity
                let returnToMe = activity == .browsing || (activity == .navigating && !overviewChosen)
                if camera.currentCameraState == .idle, returnToMe {
                    idle += 1
                    if idle >= 4 { camera.update(cameraState: .following); idle = 0 }
                } else {
                    idle = 0
                }
            }
        }
    }

    /// Routenvorschau oder Routenübersicht während der Fahrt: dann keine Freunde auf der Karte
    private var showsRouteOverview: Bool {
        manager.currentActivity == .previewing
            || (manager.currentActivity == .navigating
                && overviewChosen)
    }

    private var friendsShown: Bool { friendsVisible && !showsRouteOverview }

    /// Leiste und Kartenknöpfe nach ein paar Sekunden ausblenden – mit und ohne Route, Tippen holt sie zurück.
    /// (Standard bei CarPlay: Leiste blendet aus, Kartenknöpfe bleiben stehen.)
    private func autoHideButtons() {
        for case let template as CPMapTemplate in manager.interfaceController?.templates ?? [] {
            template.automaticallyHidesNavigationBar = true
            template.hidesButtonsWithNavigationBar = true
        }
    }

    private func refreshFriends() {
        browseOverlay?.refresh()
        navigationOverlay?.refresh()
        flyover?.refreshFriends()
    }

    lazy var manager: CarPlayManager = {
        let m = CarPlayManager(navigationProvider: navigationProvider, styles: NavigationStyles.carPlay())
        m.delegate = self
        return m
    }()

    func connect(scene: CPTemplateApplicationScene, interfaceController: CPInterfaceController, window: CPWindow) {
        manager.delegate = self
        manager.templateApplicationScene(scene, didConnect: interfaceController, to: window)
        isConnected = true
        let config = CPSessionConfiguration(delegate: self)
        session = config
        Diag.log("CarPlay verbunden, vom Auto gesperrt: \(Self.describe(config.limitedUserInterfaces))")
        AppModel.shared.location.setCarPlay(true)
        watchInvites()
        startSpeedWarning()
        // Läuft auf dem iPhone schon eine Navigation, übernimmt CarPlay sie
        if AppModel.shared.navigation.isNavigating {
            beginNavigationIfConnected()
        }
    }

    func disconnect(scene: CPTemplateApplicationScene, interfaceController: CPInterfaceController, window: CPWindow) {
        browseOverlay?.stop()
        navigationOverlay?.stop()
        browseOverlay = nil
        navigationOverlay = nil
        browseRecenter?.cancel(); browseRecenter = nil
        navRecenter?.cancel(); navRecenter = nil
        flyover?.detach(); flyover = nil
        manager.templateApplicationScene(scene, didDisconnect: interfaceController, from: window)
        manager.delegate = nil
        session = nil
        stopSpeedWarning()
        isConnected = false
        AppModel.shared.location.setCarPlay(false)
        searchTask?.cancel()
        searchTask = nil
        searchCompletion = nil
    }

    func beginNavigationIfConnected() {
        guard isConnected, manager.currentActivity != .navigating,
              let location = AppModel.shared.location.lastLocation
        else { return }
        manager.beginNavigationWithCarPlay(using: location.coordinate)
    }

    func endNavigationIfNeeded() {
        guard isConnected, manager.currentActivity == .navigating else { return }
        manager.carPlayNavigationViewController?.exitNavigation(byCanceling: true)
    }

    // MARK: Freunde-Schaltfläche und Freundesliste

    private func friendsButton() -> CPMapButton {
        let button = CPMapButton { [weak self] _ in
            guard let self else { return }
            friendsVisible.toggle()
            refreshFriends()
            // Symbol sofort umschalten. (Vorher lief das über resetPanButtons – das tut nur bei
            // eingeblendeter Verschiebe-Ansicht etwas, darum blieb der Knopf scheinbar ohne Funktion.)
            let controller = manager.interfaceController
            if let template = (controller?.topTemplate as? CPMapTemplate) ?? (controller?.rootTemplate as? CPMapTemplate) {
                template.mapButtons = manager.currentActivity == .navigating ? navigationMapButtons() : mapButtons()
            }
        }
        let symbol = friendsVisible ? "person.2.fill" : "person.2.slash"
        button.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        return button
    }

    /// Ziele aus Meeterz: vereinbarte Treffpunkte und Freunde
    private func destinationsTemplate() -> CPListTemplate {
        let model = AppModel.shared

        let meetupItems: [CPListItem] = model.meetups.accepted.map { meetup in
            let item = CPListItem(text: meetup.placeName, detailText: "Treffen mit \(meetup.otherName)")
            item.handler = { [weak self] _, completion in
                self?.preview(to: meetup.coordinate, name: meetup.placeName, completion: completion)
            }
            return item
        }

        let friendItems: [CPListItem] = model.friendsOnMap.map { item in
            let route = model.routes.friendRoutes[item.friend.friendId]
            let detail = route.flatMap { r in r.destinationName.map { "Unterwegs nach \($0)" } } ?? "Zum aktuellen Standort"
            let listItem = CPListItem(text: item.friend.displayName, detailText: detail)
            listItem.handler = { [weak self] _, completion in
                self?.preview(to: item.position.coordinate, name: item.friend.displayName, completion: completion)
            }
            return listItem
        }

        let inviteItems: [CPListItem] = model.meetups.incomingPending.map { meetup in
            let item = CPListItem(text: meetup.placeName, detailText: "Einladung von \(meetup.otherName)")
            item.handler = { [weak self] _, completion in
                self?.presentInvite(meetup)
                completion()
            }
            return item
        }

        // Wie bei Apple Karten ganz oben: Zuhause, Arbeit und eigene Favoriten mit Symbol
        let favorites = model.favorites
        let favoriteItems: [CPListItem] = ([favorites.home, favorites.work].compactMap { $0 } + favorites.others).map { fav in
            let item = CPListItem(text: fav.label, detailText: fav.address,
                                  image: UIImage(systemName: fav.symbol,
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)))
            item.handler = { [weak self] _, completion in
                self?.preview(to: fav.coordinate, name: fav.label, completion: completion)
            }
            return item
        }

        // Fahrzeit zu Zuhause und Arbeit nachreichen, sobald sie berechnet ist
        for (item, fav) in zip(favoriteItems, [favorites.home, favorites.work].compactMap { $0 } + favorites.others)
        where fav.kind != .other {
            Task { @MainActor in
                guard let seconds = await model.navigation.driveTime(to: fav.coordinate) else { return }
                item.setDetailText("\(Format.minutes(seconds: seconds)) · \(fav.address ?? fav.label)")
            }
        }

        let recentItems: [CPListItem] = model.recents.items
            .filter { r in !favorites.items.contains { $0.coordinate.distance(to: r.coordinate) < 50 } }
            .prefix(5).map { recent in
                let item = CPListItem(text: recent.name, detailText: recent.address,
                                      image: UIImage(systemName: "clock.fill",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)))
                item.handler = { [weak self] _, completion in
                    self?.preview(to: recent.coordinate, name: recent.name, completion: completion)
                }
                return item
            }

        var sections: [CPListSection] = []
        if !favoriteItems.isEmpty { sections.append(CPListSection(items: favoriteItems, header: "Favoriten", sectionIndexTitle: nil)) }
        if !recentItems.isEmpty { sections.append(CPListSection(items: recentItems, header: "Zuletzt", sectionIndexTitle: nil)) }
        if !inviteItems.isEmpty { sections.append(CPListSection(items: inviteItems, header: "Einladungen", sectionIndexTitle: nil)) }
        if !meetupItems.isEmpty { sections.append(CPListSection(items: meetupItems, header: "Treffpunkte", sectionIndexTitle: nil)) }
        sections.append(CPListSection(items: friendItems.isEmpty
            ? [CPListItem(text: "Gerade ist niemand unterwegs", detailText: nil)]
            : friendItems,
            header: "Freunde", sectionIndexTitle: nil))
        return CPListTemplate(title: "Ziele", sections: sections)
    }

    private func preview(to coordinate: CLLocationCoordinate2D, name: String, completion: @escaping () -> Void) {
        let waypoint = Waypoint(coordinate: coordinate, name: name)
        pendingDestination = Place(id: UUID().uuidString, name: name, address: nil, coordinate: coordinate)
        // Eigene Routenoptionen: Deutsch (sonst gilt die Systemsprache des iPhones, z. B. Englisch) und Auto
        guard let here = AppModel.shared.location.lastLocation else {
            manager.previewRoutes(to: waypoint, completionHandler: completion)
            return
        }
        let options = NavigationRouteOptions(
            waypoints: [Waypoint(location: here, name: "Aktueller Standort"), waypoint],
            profileIdentifier: .automobileAvoidingTraffic,
            locale: Locale.navigation,
            distanceUnit: .kilometer)
        manager.previewRoutes(for: options, completionHandler: completion)
    }

    private var pendingDestination: Place?

    // MARK: Einladungen empfangen

    /// Neue Einladungen als Hinweis mit Annehmen/Ablehnen anzeigen
    private func watchInvites() {
        guard isConnected else { return }
        withObservationTracking {
            _ = AppModel.shared.meetups.incomingPending
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                self.presentNewInvites()
                self.watchInvites()
            }
        }
        presentNewInvites()
    }

    private func presentNewInvites() {
        guard let controller = manager.interfaceController, controller.presentedTemplate == nil else { return }
        guard let meetup = AppModel.shared.meetups.incomingPending.first(where: { !shownInvites.contains($0.id) }) else { return }
        shownInvites.insert(meetup.id)
        presentInvite(meetup)
    }

    private func presentInvite(_ meetup: Meetup) {
        guard let controller = manager.interfaceController else { return }
        let alert = CPAlertTemplate(
            titleVariants: ["\(meetup.otherName) lädt dich ein: \(meetup.placeName)", "\(meetup.otherName) lädt dich ein"],
            actions: [
                CPAlertAction(title: "Annehmen", style: .default) { [weak self] _ in
                    self?.manager.interfaceController?.dismissTemplate(animated: true, completion: nil)
                    Task { @MainActor in
                        await AppModel.shared.meetups.respond(meetup, accept: true)
                        self?.go(to: meetup.place)
                    }
                },
                CPAlertAction(title: "Ablehnen", style: .cancel) { [weak self] _ in
                    self?.manager.interfaceController?.dismissTemplate(animated: true, completion: nil)
                    Task { @MainActor in await AppModel.shared.meetups.respond(meetup, accept: false) }
                },
            ]
        )
        controller.presentTemplate(alert, animated: true, completion: nil)
    }

    /// Läuft schon eine Navigation, wird der Ort Zwischenstopp, sonst Routenvorschau
    func go(to place: Place) {
        if AppModel.shared.navigation.isNavigating {
            Task { await AppModel.shared.navigation.addStop(place) }
        } else {
            preview(to: place.coordinate, name: place.name) {}
        }
    }

    var inviteDestination: Place? {
        AppModel.shared.navigation.destination ?? pendingDestination
    }

    /// Während der Fahrt: Stopp hinzufügen und Freunde zum Fahrtziel einladen
    private func showInviteList() {
        let model = AppModel.shared
        guard let place = inviteDestination else { return }
        let friends = model.friends.accepted
        guard !friends.isEmpty else { return }

        let stop = CPListItem(text: "Stopp hinzufügen", detailText: nil,
                              image: UIImage(systemName: "plus.circle.fill"))
        stop.handler = { [weak self] _, done in
            self?.manager.interfaceController?.popTemplate(animated: false, completion: nil)
            self?.showSearchHub()
            done()
        }
        var items: [CPListItem] = [stop]
        if friends.count > 1 {
            let all = CPListItem(text: "Alle einladen", detailText: nil)
            all.handler = { [weak self] _, done in
                self?.sendInvites(to: friends.map(\.friendId), place: place)
                self?.manager.interfaceController?.popTemplate(animated: true, completion: nil)
                done()
            }
            items.append(all)
        }
        for friend in friends.prefix(max(0, CPListTemplate.maximumItemCount - items.count)) {
            let detail = friendArrival(friend.friendId, at: place).map { "Kommt auch hierher · an \(Format.time.string(from: $0))" } ?? "Einladen"
            let item = CPListItem(text: friend.displayName, detailText: detail)
            item.handler = { [weak self] _, done in
                self?.sendInvites(to: [friend.friendId], place: place)
                self?.manager.interfaceController?.popTemplate(animated: true, completion: nil)
                done()
            }
            items.append(item)
        }
        let template = CPListTemplate(title: place.name, sections: [CPListSection(items: items)])
        manager.interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func sendInvites(to ids: [UUID], place: Place) {
        Task { @MainActor in
            var sent = 0
            for id in ids where await AppModel.shared.meetups.propose(to: id, place: place, silent: true) { sent += 1 }
            showNotice(sent == 0 ? "Einladung fehlgeschlagen."
                                 : sent == 1 ? "Einladung gesendet." : "\(sent) Einladungen gesendet.")
        }
    }

    private func showNotice(_ text: String) {
        guard let controller = manager.interfaceController, controller.presentedTemplate == nil else { return }
        let alert = CPAlertTemplate(titleVariants: [text], actions: [
            CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.manager.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
        ])
        controller.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: Suche (Tastatur im Stand, Diktat beim Fahren – das entscheidet CarPlay selbst)

    func showSearch() {
        Diag.log("CarPlay-Suche geöffnet, vom Auto gesperrt: \(Self.describe(session?.limitedUserInterfaces ?? []))")
        let template = CPSearchTemplate()
        template.delegate = self
        manager.interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
}

extension CarPlayController: CPSearchTemplateDelegate {
    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        MainActor.assumeIsolated {
            Diag.log("CarPlay-Suche: Eingabe \(searchText.count) Zeichen")
            searchCompletion?([])
            searchTask?.cancel()
            searchCompletion = completionHandler
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard query.count >= 3 else {
                completionHandler([])
                searchCompletion = nil
                return
            }
            searchTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))   // Tippen bzw. Diktat abwarten
                guard !Task.isCancelled else { return }
                let near = AppModel.shared.location.lastLocation?.coordinate
                let places = (try? await SearchService.search(query, near: near)) ?? []
                guard !Task.isCancelled, let self else { return }
                let items: [CPListItem] = places.prefix(CPListTemplate.maximumItemCount).map { place in
                    let item = CPListItem(text: place.name, detailText: place.address)
                    item.userInfo = place
                    return item
                }
                self.searchCompletion?(items)
                self.searchCompletion = nil
            }
        }
    }

    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            guard let place = item.userInfo as? Place else { completionHandler(); return }
            manager.interfaceController?.popToRootTemplate(animated: true, completion: nil)
            if AppModel.shared.navigation.isNavigating {
                go(to: place)            // läuft schon eine Fahrt: Ort wird Zwischenstopp
                completionHandler()
            } else {
                preview(to: place.coordinate, name: place.name, completion: completionHandler)
            }
        }
    }
}

extension CarPlayController: CarPlayManagerDelegate {
    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, didSetup navigationMapView: NavigationMapView) {
        MainActor.assumeIsolated {
            browseOverlay?.stop()
            Satellite3DBuildings.install(
                on: navigationMapView.mapView,
                satellite: UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true
            )
            let overlay = FriendOverlay(mapView: navigationMapView.mapView) { [weak self] in self?.friendsShown ?? true }
            overlay.start()
            browseOverlay = overlay
            configureCamera(navigationMapView, navigating: false)
            autoHideButtons()
            browseRecenter?.cancel()
            browseRecenter = startAutoRecenter(navigationMapView)
            if CarPlayFlyoverMirror.isEnabled {
                let mirror = flyover ?? CarPlayFlyoverMirror { [weak self] in self?.friendsShown ?? true }
                flyover = mirror
                mirror.attach(to: navigationMapView)
            }
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        didPresent navigationViewController: CarPlayNavigationViewController
    ) {
        MainActor.assumeIsolated {
            navigationViewController.routeLineTracksTraversal = true
            guard let mapView = navigationViewController.navigationMapView?.mapView else { return }
            navigationOverlay?.stop()
            Satellite3DBuildings.install(
                on: mapView,
                satellite: UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true
            )
            let overlay = FriendOverlay(mapView: mapView) { [weak self] in self?.friendsShown ?? true }
            overlay.start()
            navigationOverlay = overlay
            if let navMap = navigationViewController.navigationMapView {
                navZoom = nil
                overviewChosen = false
                configureCamera(navMap, navigating: true)
                autoHideButtons()
                navRecenter?.cancel()
                navRecenter = startAutoRecenter(navMap)
                flyover?.showPreview(nil)
                flyover?.attach(to: navMap)
            }
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        mapButtonsCompatibleWith traitCollection: UITraitCollection,
        in template: CPTemplate,
        for activity: CarPlayActivity
    ) -> [CPMapButton]? {
        MainActor.assumeIsolated {
            switch activity {
            case .browsing:
                return mapButtons()
            case .navigating:
                return navigationMapButtons()
            case .previewing, .panningInBrowsingMode, .panningInNavigationMode:
                return nil
            }
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        leadingNavigationBarButtonsCompatibleWith traitCollection: UITraitCollection,
        in carPlayTemplate: CPMapTemplate,
        for activity: CarPlayActivity,
        cameraState: NavigationCameraState
    ) -> [CPBarButton]? {
        MainActor.assumeIsolated {
            // Links bleibt die Leiste frei (2D/3D sitzt rechts bei den Kartenknöpfen);
            // während der Fahrt Mapbox-Standard (Stummschalten, Alternativen)
            let buttons: [CPBarButton]? = activity == .browsing ? [] : nil
            return buttons
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        trailingNavigationBarButtonsCompatibleWith traitCollection: UITraitCollection,
        in template: CPMapTemplate,
        for activity: CarPlayActivity
    ) -> [CPBarButton]? {
        MainActor.assumeIsolated {
            switch activity {
            case .browsing:
                let search = CPBarButton(title: "Suche") { [weak self] _ in self?.showSearchHub() }
                let goals = CPBarButton(title: "Ziele") { [weak self] _ in
                    guard let self else { return }
                    manager.interfaceController?.pushTemplate(destinationsTemplate(), animated: true, completion: nil)
                }
                return [search, goals]
            case .navigating:
                // „Beenden“ muss immer da sein (der Mapbox-Standardknopf entfällt, sobald wir die Leiste belegen).
                // Kein dauerhaftes Fenster über der Karte – Einladen und Stopp öffnen sich nur auf Knopfdruck.
                let end = CPBarButton(title: "Beenden") { [weak self] _ in self?.endNavigationIfNeeded() }
                if !AppModel.shared.friends.accepted.isEmpty, inviteDestination != nil {
                    let more = CPBarButton(title: "Einladen") { [weak self] _ in self?.showInviteList() }
                    return [more, end]
                }
                let stop = CPBarButton(title: "Stopp") { [weak self] _ in self?.showSearchHub() }
                return [stop, end]
            case .previewing, .panningInBrowsingMode, .panningInNavigationMode:
                return nil
            }
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        selectedPreviewFor trip: CPTrip,
        using routeChoice: CPRouteChoice
    ) {
        MainActor.assumeIsolated {
            flyover?.showPreview(routeChoice.navigationRoutes)
            refreshFriends()
        }
    }

    nonisolated func carPlayManagerDidCancelPreview(_ carPlayManager: CarPlayManager) {
        MainActor.assumeIsolated {
            flyover?.showPreview(nil)
            refreshFriends()
        }
    }

    nonisolated func carPlayManagerDidBeginNavigation(_ carPlayManager: CarPlayManager) {
        MainActor.assumeIsolated {
            let coordinator = AppModel.shared.navigation
            if !coordinator.isNavigating {
                coordinator.didBeginOnCarPlay(destination: pendingDestination)
            }
            refreshFriends()
            announceFriendsHeadingToDestination()
        }
    }

    nonisolated func carPlayManagerDidEndNavigation(_ carPlayManager: CarPlayManager, byCanceling canceled: Bool) {
        MainActor.assumeIsolated {
            navigationOverlay?.stop()
            navigationOverlay = nil
            navRecenter?.cancel(); navRecenter = nil
            navZoom = nil
            overviewChosen = false
            autoHideButtons()
            if let browseMap = carPlayManager.carPlayMapViewController?.navigationMapView {
                flyover?.attach(to: browseMap)
            }
            pendingDestination = nil
            AppModel.shared.navigation.stop()
            refreshFriends()
        }
    }

    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, shouldPresentArrivalUIFor waypoint: Waypoint) -> Bool {
        true
    }
}

extension CarPlayController: CPSessionConfigurationDelegate {
    nonisolated func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        MainActor.assumeIsolated {
            Diag.log("CarPlay: vom Auto gesperrt jetzt \(Self.describe(limitedUserInterfaces))")
        }
    }

    static func describe(_ limits: CPLimitableUserInterface) -> String {
        var parts: [String] = []
        if limits.contains(.keyboard) { parts.append("Tastatur") }
        if limits.contains(.lists) { parts.append("Listen") }
        return parts.isEmpty ? "nichts" : parts.joined(separator: ", ")
    }
}
