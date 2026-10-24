import Foundation
import UIKit
import Combine
import CarPlay
import CoreLocation
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit
import MapboxMaps
import MapKit

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

    /// Vom Dashboard geöffnet (meeterz://carplay/route): die große Ansicht ist jetzt vorn – Fahrt starten
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        MainActor.assumeIsolated {
            guard URLContexts.contains(where: { $0.url.host == "carplay" }) else { return }
            CarPlayController.shared.consumeDashboardRequest()
        }
    }
}

/// Karte mit Freunden, Navigation (über Mapbox CarPlayManager), Freundesliste als Ziele.
@MainActor
final class CarPlayController: NSObject {
    static let shared = CarPlayController()

    private(set) var isConnected = false
    private var friendsVisible = true
    private var _lastMapInteraction = Date.distantPast
    private var userPanning = false
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
    /// Die Mapbox-Karte, die gerade auf dem Autodisplay zu sehen ist
    var displayedMap: NavigationMapView? {
        if let nav = navMap, nav.window != nil { return nav }
        return browseMap
    }

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
        lastMapInteraction = Date()
        threeD.toggle()
        configureCamera(browseMap, navigating: false)
        configureCamera(navMap, navigating: true)
    }

    /// Menü „Kartenansicht“
    private func showMapStyleMenu() {
        lastMapInteraction = Date()
        let d = UserDefaults.standard
        let flyover = CarPlayFlyoverMirror.isEnabled
        let satellite = d.object(forKey: "carplay.satellite") as? Bool ?? true
        let current = flyover ? "flyover" : (satellite ? "satellite" : "classic")
        let check = UIImage(systemName: "checkmark")
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

        func styleItem(_ key: String, _ title: String, _ symbol: String) -> CPListItem {
            let item = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol, withConfiguration: config),
                                  accessoryImage: key == current ? check : nil, accessoryType: .none)
            item.handler = { [weak self] _, done in
                d.set(key == "flyover", forKey: "carplay.flyover")
                if key != "flyover" { d.set(key == "satellite", forKey: "carplay.satellite") }
                self?.applyMapStyle()
                done()
                self?.manager.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            return item
        }
        func viewItem(_ three: Bool) -> CPListItem {
            let item = CPListItem(text: three ? "3D" : "2D", detailText: three ? "Geneigt, mit Gebäuden" : "Von oben",
                                  image: UIImage(systemName: three ? "view.3d" : "map", withConfiguration: config),
                                  accessoryImage: threeD == three ? check : nil, accessoryType: .none)
            item.handler = { [weak self] _, done in
                if let self, threeD != three { toggleThreeD() }
                done()
                self?.manager.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            return item
        }
        let template = CPListTemplate(title: "Kartenansicht", sections: [
            CPListSection(items: [styleItem("satellite", "Satellit", "globe.europe.africa.fill"),
                                  styleItem("classic", "Klassisch", "map.fill"),
                                  styleItem("flyover", "Apple Flyover (experimentell)", "building.2.fill")],
                          header: "Karte", sectionIndexTitle: nil),
            CPListSection(items: [viewItem(true), viewItem(false)], header: "Ansicht", sectionIndexTitle: nil),
        ])
        manager.interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// +/−: ändert den Zoom der Folgekamera statt die Kamera anzuhalten – so springt nichts zurück
    /// Flyover kann nicht so nah heran wie Mapbox – dort weniger weit hineinzoomen lassen
    private var maxZoom: Double { CarPlayFlyoverMirror.isEnabled ? 17.5 : 19 }

    private func zoom(by delta: Double) {
        lastMapInteraction = Date()
        if manager.currentActivity == .navigating, let map = navMap {
            overviewChosen = false
            refreshFriends()
            let now = navZoom ?? map.mapView.mapboxMap?.cameraState.zoom ?? 16
            navZoom = min(max(now + delta, 10), maxZoom)
            configureCamera(map, navigating: true)
        } else {
            browseZoom = min(max(browseZoom + delta, 10), maxZoom)
            configureCamera(browseMap, navigating: false)
        }
    }

    /// Die vier Kartenknöpfe (CarPlay erlaubt höchstens vier): Freunde, 2D/3D, +, −.
    /// Zentrieren braucht es nicht – die Karte kehrt nach 4 s von selbst zum Standort zurück.
    private func mapButtons() -> [CPMapButton] {
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        // Kartenansicht: Stil (Satellit/Klassisch/Flyover) und 2D/3D in einem Menü – wie in der App
        let three = CPMapButton { [weak self] _ in self?.showMapStyleMenu() }
        three.image = UIImage(systemName: "square.3.layers.3d", withConfiguration: config)
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
    /// Letzte Bedienung der Karte (Verschieben, Zoom, 3D) und ob gerade verschoben wird
    private var lastMapInteraction: Date {
        get { _lastMapInteraction }
        set { _lastMapInteraction = newValue }
    }

    private func startAutoRecenter(_ navigationMapView: NavigationMapView) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak navigationMapView] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let camera = navigationMapView?.navigationCamera else { return }
                let activity = manager.currentActivity
                let returnToMe = (activity == .browsing && !isLoadingPreview) || (activity == .navigating && !overviewChosen)
                // Erst zurück zu mir, wenn 15 s lang niemand die Karte bewegt hat. Vorher zählte die Uhr ab dem
                // ersten Verschieben weiter – wer länger schob, wurde nach 4 s mitten im Verschieben zurückgeholt.
                guard camera.currentCameraState == .idle, returnToMe, !userPanning,
                      Date().timeIntervalSince(lastMapInteraction) >= 15 else { continue }
                camera.update(cameraState: .following)
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

    func refreshFriendsAfterPassengerChange() {
        refreshFriends()
        CarPlayDashboard.shared.updateShortcuts()
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
        DriveHealth.shared.start()
        manager.delegate = self
        // Lädt das Auto schon (z. B. CarPlay an der Säule neu verbunden): Ladeanzeige zeigen, sobald die Karte steht
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if ChargingSession.shared.active { CarPlayChargingOverlay.shared.show() }
        }
        manager.templateApplicationScene(scene, didConnect: interfaceController, to: window)
        isConnected = true
        let config = CPSessionConfiguration(delegate: self)
        session = config
        Diag.log("CarPlay verbunden, vom Auto gesperrt: \(Self.describe(config.limitedUserInterfaces)), Standort präzise: \(CLLocationManager().accuracyAuthorization == .fullAccuracy), letzte Genauigkeit: \(Int(AppModel.shared.location.lastLocation?.horizontalAccuracy ?? -1)) m")
        AppModel.shared.location.setCarPlay(true)
        NavigationLiveActivityController.shared.end()   // im Auto nur die CarPlay-Anzeige, keine doppelte Kachel
        AppModel.shared.parking.clear()                  // wieder im Auto: alter Parkplatz ist erledigt
        watchInvites()
        startSpeedWarning()
        // Läuft auf dem iPhone schon eine Navigation, übernimmt CarPlay sie
        if AppModel.shared.navigation.isNavigating {
            beginNavigationIfConnected()
        }
    }

    func disconnect(scene: CPTemplateApplicationScene, interfaceController: CPInterfaceController, window: CPWindow) {
        DriveHealth.shared.stop()
        Passengers.shared.reset()   // Fahrt vorbei: Mitfahrer wieder sichtbar
        CarPlayChargingOverlay.shared.hide()
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
        // Ausgestiegen: Parkplatz merken (vor setCarPlay, das den Standort in den Sparmodus schaltet)
        if let here = AppModel.shared.location.lastLocation { AppModel.shared.parking.save(here) }
        AppModel.shared.location.setCarPlay(false)
        // Läuft die Fahrt weiter (z. B. zu Fuß das letzte Stück), übernimmt wieder die Live-Aktivität auf dem iPhone
        let nav = AppModel.shared.navigation
        if nav.isNavigating {
            NavigationLiveActivityController.shared.start(destinationName: nav.destination?.name,
                                                          destination: nav.destination?.coordinate)
        }
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
        let button = CPMapButton { [weak self] _ in self?.showFriendsMenu() }
        let symbol = friendsVisible ? "person.2.fill" : "person.2.slash"
        button.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        return button
    }

    /// Alle Freunde ein-/ausblenden (Symbol des Kartenknopfs mit umschalten)
    func setAllFriendsVisible(_ visible: Bool) {
        friendsVisible = visible
        refreshFriends()
        let controller = manager.interfaceController
        if let template = (controller?.rootTemplate as? CPMapTemplate) {
            template.mapButtons = manager.currentActivity == .navigating ? navigationMapButtons() : mapButtons()
        }
    }

    var allFriendsVisible: Bool { friendsVisible }

    /// Kurz zum Freund schwenken, nach 8 s zurück zu mir
    func focusFriend(_ coordinate: CLLocationCoordinate2D) {
        guard let map = displayedMap else { return }
        map.navigationCamera.stop()
        map.mapView.camera.ease(to: CameraOptions(center: coordinate, zoom: 15, bearing: 0, pitch: 0), duration: 0.8)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            map.navigationCamera.update(cameraState: .following)
        }
    }

    /// Ziele aus Meeterz: vereinbarte Treffpunkte und Freunde
    private func destinationsTemplate() -> CPListTemplate {
        let model = AppModel.shared

        let meetupItems: [CPListItem] = model.meetups.accepted.map { meetup in
            let item = CPListItem(text: meetup.placeName, detailText: "Treffen mit \(meetup.incoming ? meetup.withText : meetup.otherName)")
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
        // Mapbox meldet den Abschluss aus einem Hintergrund-Task; CarPlay bekommt ihn auf dem Hauptthread
        let completion = { DispatchQueue.main.async(execute: completion) }
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

    /// Ziel aus einer Liste gewählt: sofort zur Karte, Kamera zeigt Start und Ziel, am Ziel dreht ein Ladekreis.
    /// Sobald die Route da ist, öffnet Mapbox die Vorschau und rahmt die Route ein.
    /// (Vorher passierte bei schlechtem Netz sichtbar nichts – es wirkte eingefroren.)
    func select(_ place: Place, done: @escaping () -> Void) {
        if AppModel.shared.navigation.isNavigating {
            Task { @MainActor in
                await AppModel.shared.navigation.addStop(place)   // läuft schon eine Fahrt: Zwischenstopp
                manager.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                done()
            }
            return
        }
        manager.interfaceController?.popToRootTemplate(animated: true, completion: nil)
        done()
        showLoading(at: place)
        preview(to: place.coordinate, name: place.name) { [weak self] in
            MainActor.assumeIsolated { self?.hideLoading() }
        }
    }

    // MARK: Ladephase bis zur Routenvorschau

    private var loadingView: RouteLoadingView?
    private var loadingTarget: CLLocationCoordinate2D?
    private var loadingTimer: Timer?
    var isLoadingPreview: Bool { loadingView != nil }

    private func showLoading(at place: Place) {
        hideLoading()
        guard let host = manager.carPlayMapViewController?.view, let map = browseMap else { return }
        // Kamera: eigener Standort und Ziel zusammen im Bild
        if let me = AppModel.shared.location.lastLocation?.coordinate,
           let camera = try? map.mapView.mapboxMap.camera(
               for: [me, place.coordinate],
               camera: CameraOptions(bearing: 0, pitch: 0),
               coordinatesPadding: UIEdgeInsets(top: 90, left: 90, bottom: 90, right: 90),
               maxZoom: 16,
               offset: nil) {
            map.navigationCamera.stop()
            map.mapView.camera.ease(to: camera, duration: 0.6)
        }
        let view = RouteLoadingView(title: place.name)
        host.addSubview(view)
        loadingView = view
        loadingTarget = place.coordinate
        positionLoading()
        // Mitführen, während die Kamera schwenkt; nach 30 s ohne Antwort aufgeben
        var ticks = 0
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ticks += 1
                if ticks > 600 { self.hideLoading(); return }
                self.positionLoading()
            }
        }
    }

    private func positionLoading() {
        guard let view = loadingView, let target = loadingTarget, let host = view.superview else { return }
        var point: CGPoint?
        if let mirror = flyover, mirror.mapView.window != nil {
            point = mirror.mapView.convert(target, toPointTo: host)
        } else if let map = browseMap {
            point = map.convert(map.mapView.mapboxMap.point(for: target), to: host)
        }
        guard let p = point, p.x.isFinite, p.y.isFinite else { return }
        view.center = CGPoint(x: p.x, y: p.y - view.bounds.height / 2 + 14)
    }

    private func hideLoading() {
        loadingTimer?.invalidate()
        loadingTimer = nil
        loadingView?.removeFromSuperview()
        loadingView = nil
        loadingTarget = nil
    }

    // MARK: Direkt losfahren (Schnellwahl im Dashboard)

    private var autoStart = false
    private var previewTrip: CPTrip?

    /// Wartende Fahrt aus dem Dashboard (Freund oder Favorit angetippt)
    private var dashboardRequest: Place?
    /// Läuft gerade ein Start? Mehrfaches Tippen startete mehrere Berechnungen parallel – die App stürzte ab.
    private var guidanceStarting: Date?

    /// Dashboard-Knopf: sofort die große Meeterz-Ansicht öffnen (mit Ladeanzeige), dann die Fahrt starten
    func openFromDashboard(_ place: Place, scene: UIScene?) {
        guard isConnected else { return }
        if let started = guidanceStarting, Date().timeIntervalSince(started) < 20 { return }
        guidanceStarting = Date()
        dashboardRequest = place
        Diag.log("Dashboard: \(place.name) angetippt – öffne Meeterz")
        if let scene, let url = URL(string: "meeterz://carplay/route") {
            scene.open(url, options: nil) { [weak self] ok in
                Task { @MainActor in
                    if !ok { Diag.log("Dashboard: Meeterz ließ sich nicht öffnen – starte trotzdem") }
                    self?.consumeDashboardRequest()
                }
            }
        } else {
            consumeDashboardRequest()
        }
        // Falls die Rückmeldung ausbleibt, trotzdem starten
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.consumeDashboardRequest()
        }
    }

    func consumeDashboardRequest() {
        guard let place = dashboardRequest else { return }
        dashboardRequest = nil
        startGuidance(to: place, showProgress: true)
    }

    /// Route berechnen und sofort starten, ohne Vorschau
    func startGuidance(to place: Place, showProgress: Bool = false) {
        guard isConnected else { return }
        if AppModel.shared.navigation.isNavigating { guidanceStarting = nil; go(to: place); return }
        guidanceStarting = guidanceStarting ?? Date()
        autoStart = true
        if showProgress {
            manager.interfaceController?.popToRootTemplate(animated: false, completion: nil)
            showLoading(at: place)
        }
        preview(to: place.coordinate, name: place.name) { [weak self] in
            MainActor.assumeIsolated {
                self?.hideLoading()
                self?.startPendingTrip()
                self?.guidanceStarting = nil
            }
        }
    }

    private func startPendingTrip() {
        guard autoStart else { return }
        autoStart = false
        guard let trip = previewTrip, let choice = trip.routeChoices.first,
              let template = manager.interfaceController?.topTemplate as? CPMapTemplate else { return }
        manager.mapTemplate(template, startedTrip: trip, using: choice)
    }

    // MARK: Kartenstil sofort wechseln (Einstellung „Karte in CarPlay“)

    func applyMapStyle() {
        guard isConnected else { return }
        let satellite = UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true
        manager.styles = NavigationStyles.carPlay()
        for map in [browseMap, navMap].compactMap({ $0 }) {
            Satellite3DBuildings.install(on: map.mapView, satellite: satellite)
        }
        let current = manager.currentActivity == .navigating ? (navMap ?? browseMap) : (browseMap ?? navMap)
        if CarPlayFlyoverMirror.isEnabled {
            let mirror = flyover ?? CarPlayFlyoverMirror(friendsVisible: { [weak self] in self?.friendsShown ?? true },
                                                       currentMap: { [weak self] in self?.displayedMap })
            flyover = mirror
            if let current { mirror.attach(to: current) }
        } else {
            flyover?.detach()
            flyover = nil
        }
        CarPlayDashboard.shared.applyMapType()
        CarPlayDashboard.cluster.applyMapType()
        Diag.log("CarPlay: Kartenstil gewechselt (Flyover=\(CarPlayFlyoverMirror.isEnabled), Satellit=\(satellite))")
    }

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

        let stop = CPListItem(text: "Stopp hinzufügen", detailText: nil,
                              image: UIImage(systemName: "plus.circle.fill"))
        stop.handler = { [weak self] _, done in
            self?.manager.interfaceController?.popTemplate(animated: false, completion: nil)
            self?.showSearchHub()
            done()
        }
        var sections: [CPListSection] = []
        // Kurz Bescheid geben: an alle, die ich hier treffe oder die auch hierher fahren
        let partners = meetupPartners(at: place)
        if !partners.ids.isEmpty {
            let names = partners.ids.compactMap { model.friend($0)?.displayName.split(separator: " ").first.map(String.init) }
            let tell = CPListItem(text: "Kurz Bescheid geben", detailText: "an " + names.joined(separator: ", "),
                                  image: UIImage(systemName: "text.bubble.fill"))
            tell.handler = { [weak self] _, done in
                self?.showQuickReplies(to: partners.ids, meetupId: partners.meetupId, replace: true)
                done()
            }
            sections.append(CPListSection(items: [tell]))
        }
        if let convoy = convoySection() { sections.append(convoy) }
        if let charge = chargeSection() { sections.append(charge) }
        sections.append(CPListSection(items: [stop]))

        var items: [CPListItem] = []
        if friends.count > 1 {
            let all = CPListItem(text: "Alle einladen", detailText: nil)
            all.handler = { [weak self] _, done in
                self?.sendInvites(to: friends.map(\.friendId), place: place)
                self?.manager.interfaceController?.popTemplate(animated: true, completion: nil)
                done()
            }
            items.append(all)
        }
        for friend in friends.prefix(max(0, CPListTemplate.maximumItemCount - items.count - 4)) {
            let detail = friendArrival(friend.friendId, at: place).map { "Kommt auch hierher · an \(Format.time.string(from: $0))" } ?? "Einladen"
            let item = CPListItem(text: friend.displayName, detailText: detail)
            item.handler = { [weak self] _, done in
                self?.sendInvites(to: [friend.friendId], place: place)
                self?.manager.interfaceController?.popTemplate(animated: true, completion: nil)
                done()
            }
            items.append(item)
        }
        if !items.isEmpty { sections.append(CPListSection(items: items, header: "Einladen", sectionIndexTitle: nil)) }
        let template = CPListTemplate(title: place.name, sections: sections)
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
            select(place, done: completionHandler)
        }
    }
}

extension CarPlayController: CarPlayManagerDelegate {
    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, didBeginPanGesture template: CPMapTemplate) {
        MainActor.assumeIsolated { userPanning = true; lastMapInteraction = Date() }
    }

    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, didEndPanGesture template: CPMapTemplate) {
        MainActor.assumeIsolated { userPanning = false; lastMapInteraction = Date() }
    }

    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, willPreview trip: CPTrip) -> CPTrip {
        MainActor.assumeIsolated {
            let shown = Self.withBatteryForecast(trip)
            previewTrip = shown
            return shown
        }
    }

    /// E-Auto: unter jeder Routen-Option „Ankunft mit 54 %“ bzw. „1 Ladestopp · Ankunft 21 %“
    private static func withBatteryForecast(_ trip: CPTrip) -> CPTrip {
        guard EVSettings.enabled, let vehicle = EVSettings.vehicle else { return trip }
        let settings = EVSettings.plannerSettings
        let start = EVSettings.chargePercent
        var changed = false
        let choices: [CPRouteChoice] = trip.routeChoices.map { choice in
            guard let route = mainRoute(in: choice.userInfo) else { return choice }
            let text: String
            switch ChargePlanner.plan(route: route, vehicle: vehicle, startPercent: start, settings: settings, sites: ChargeSites.all) {
            case .success(let plan) where plan.direct: text = "Ankunft mit \(Int(plan.arrivalPercent.rounded())) %"
            case .success(let plan): text = "\(plan.stops.count == 1 ? "1 Ladestopp" : "\(plan.stops.count) Ladestopps") · Ankunft \(Int(plan.arrivalPercent.rounded())) %"
            case .failure: text = "Akku reicht nicht – kein Ladeplan"
            }
            changed = true
            let info = (choice.additionalInformationVariants ?? []).map { "\(text) · \($0)" }
            let copy = CPRouteChoice(summaryVariants: choice.summaryVariants,
                                     additionalInformationVariants: info.isEmpty ? [text] : info,
                                     selectionSummaryVariants: choice.selectionSummaryVariants ?? [])
            copy.userInfo = choice.userInfo
            return copy
        }
        guard changed else { return trip }
        let copy = CPTrip(origin: trip.origin, destination: trip.destination, routeChoices: choices)
        copy.userInfo = trip.userInfo
        return copy
    }

    /// Mapbox legt die Routen intern in `userInfo` ab (Typ nicht öffentlich) – per Spiegelung auslesen
    private static func mainRoute(in userInfo: Any?) -> Route? {
        let values: [Any]
        if let dict = userInfo as? [String: Any?] { values = dict.values.compactMap { $0 } }
        else if let dict = userInfo as? [String: Any] { values = Array(dict.values) }
        else { return nil }
        for value in values {
            for child in Mirror(reflecting: value).children where child.label == "navigationRoutes" {
                if let routes = child.value as? NavigationRoutes { return routes.mainRoute.route }
                if let optional = child.value as? NavigationRoutes? , let routes = optional { return routes.mainRoute.route }
            }
        }
        return nil
    }

    /// Route nicht berechenbar (z. B. kein Netz): Hinweis statt Stille
    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        didFailToFetchRouteBetween waypoints: [Waypoint]?,
        options: RouteOptions,
        error: Error
    ) -> CPNavigationAlert? {
        Diag.log("CarPlay: Route fehlgeschlagen – \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.autoStart = false
            self?.hideLoading()
        }
        return CPNavigationAlert(
            titleVariants: ["Route konnte nicht berechnet werden", "Keine Route"],
            subtitleVariants: ["Prüfe die Internetverbindung und versuche es erneut."],
            image: UIImage(systemName: "wifi.exclamationmark"),
            primaryAction: CPAlertAction(title: "OK", style: .cancel) { _ in },
            secondaryAction: nil,
            duration: 8)
    }

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
                let mirror = flyover ?? CarPlayFlyoverMirror(friendsVisible: { [weak self] in self?.friendsShown ?? true },
                                                       currentMap: { [weak self] in self?.displayedMap })
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
            // Mapbox baut für Kartenansicht, Navigation und nach dem Ende je eine neue Vorlage – hier kommt jede
            // vorbei, bevor sie angezeigt wird. Vorher wurde das Ausblenden nur in Rückrufen gesetzt, die vor dem
            // Anlegen der Vorlage kamen: „Knöpfe mit der Leiste ausblenden“ blieb aus, die Knöpfe standen immer.
            if let map = template as? CPMapTemplate {
                map.automaticallyHidesNavigationBar = true
                map.hidesButtonsWithNavigationBar = true
            }
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
                if inviteDestination != nil, !AppModel.shared.friends.accepted.isEmpty || EVSettings.enabled {
                    let more = CPBarButton(title: "Mehr") { [weak self] _ in self?.showInviteList() }
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
            // Akku-Kästchen, sobald die Navigationsansicht steht
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                ChargeMonitor.shared.updateForecast()
            }
            refreshFriends()
            announceFriendsHeadingToDestination()
            // E-Auto: kurz warten, bis Restweg berechnet ist, dann prüfen, ob der Akku reicht
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.checkCharge()
            }
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
            ConvoyTracker.shared.reset()
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

/// Ziel-Markierung mit Ladekreis und Namen, solange die Route berechnet wird
final class RouteLoadingView: UIView {
    init(title: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 180, height: 84))
        isUserInteractionEnabled = false

        let ring = UIView(frame: CGRect(x: 66, y: 0, width: 48, height: 48))
        ring.backgroundColor = UIColor(red: 0.024, green: 0.165, blue: 0.196, alpha: 0.9)
        ring.layer.cornerRadius = 24
        ring.layer.borderColor = Theme.mintUI.cgColor
        ring.layer.borderWidth = 2
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.center = CGPoint(x: 24, y: 24)
        spinner.startAnimating()
        ring.addSubview(spinner)
        addSubview(ring)

        let label = UILabel(frame: CGRect(x: 0, y: 54, width: 180, height: 24))
        label.text = title
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor(red: 0.024, green: 0.165, blue: 0.196, alpha: 0.9)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        let width = min(180, label.intrinsicContentSize.width + 20)
        label.frame = CGRect(x: (180 - width) / 2, y: 54, width: width, height: 24)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
}
