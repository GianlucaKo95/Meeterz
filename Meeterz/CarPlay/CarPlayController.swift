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
    private var threeDBarButton: CPBarButton?
    private var threeDMapButton: CPMapButton?

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

    /// Neigung der Kamera im Folgemodus setzen (3D = 60°, 2D = 0°)
    private func applyPitch(to navigationMapView: NavigationMapView?) {
        guard let camera = navigationMapView?.navigationCamera else { return }
        if let source = camera.viewportDataSource as? CarPlayViewportDataSource {
            source.options.followingCameraOptions.defaultPitch = threeD ? 60 : 0
        }
        if camera.currentCameraState == .following { camera.update(cameraState: .following) }
    }

    private func toggleThreeD() {
        threeD.toggle()
        applyPitch(to: manager.carPlayMapViewController?.navigationMapView)
        applyPitch(to: manager.carPlayNavigationViewController?.navigationMapView)
        threeDBarButton?.title = threeD ? "2D" : "3D"
        threeDMapButton?.image = Self.textImage(threeD ? "2D" : "3D")
    }

    /// Kehrt nach 4 s ohne Eingabe zum Standort zurück, wenn man die Karte weggeschoben hat
    private func startAutoRecenter(_ navigationMapView: NavigationMapView) -> Task<Void, Never> {
        Task { @MainActor [weak navigationMapView] in
            var idle = 0
            var lost = 0
            var token: AnyCancellable?
            if let navigationMapView {
                token = navigationMapView.navigationCamera.cameraStates.sink { Diag.log("CarPlay-Kamera → \($0)") }
            }
            defer { token?.cancel() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let navigationMapView, let camera = Optional(navigationMapView.navigationCamera) else { return }
                // Wachhund: Kamera meldet „folgen“, der Standortpunkt wandert aber aus dem Bild (iOS 18) → Folgen neu anstoßen
                if camera.currentCameraState == .following,
                   let me = navigationMapView.mapView.location.latestLocation?.coordinate,
                   let map = navigationMapView.mapView.mapboxMap {
                    let p = map.point(for: me)
                    let b = navigationMapView.bounds.insetBy(dx: 8, dy: 8)
                    if b.width > 1, !b.contains(p) { lost += 1 } else { lost = 0 }
                    if lost >= 3 {
                        Diag.log("Standort außerhalb des Bildes trotz .following (Punkt \(Int(p.x)),\(Int(p.y)), Bild \(Int(navigationMapView.bounds.width))x\(Int(navigationMapView.bounds.height)), Kameramitte \(map.cameraState.center.latitude),\(map.cameraState.center.longitude), Standort \(me.latitude),\(me.longitude))")
                        camera.stop()
                        camera.update(cameraState: .following)
                        lost = 0
                    }
                } else {
                    lost = 0
                }
                if camera.currentCameraState == .idle {
                    idle += 1
                    if idle >= 4 { camera.update(cameraState: .following); idle = 0 }
                } else {
                    idle = 0
                }
            }
        }
    }

    private lazy var manager: CarPlayManager = {
        let m = CarPlayManager(navigationProvider: navigationProvider, styles: NavigationStyles.carPlay())
        m.delegate = self
        return m
    }()

    func connect(scene: CPTemplateApplicationScene, interfaceController: CPInterfaceController, window: CPWindow) {
        manager.delegate = self
        manager.templateApplicationScene(scene, didConnect: interfaceController, to: window)
        isConnected = true
        AppModel.shared.location.setCarPlay(true)
        watchInvites()
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
            browseOverlay?.refresh()
            navigationOverlay?.refresh()
            if let template = manager.interfaceController?.topTemplate as? CPMapTemplate {
                manager.resetPanButtons(template)
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

        var sections: [CPListSection] = []
        if !inviteItems.isEmpty { sections.append(CPListSection(items: inviteItems, header: "Einladungen", sectionIndexTitle: nil)) }
        if !meetupItems.isEmpty { sections.append(CPListSection(items: meetupItems, header: "Treffpunkte", sectionIndexTitle: nil)) }
        sections.append(CPListSection(items: friendItems.isEmpty
            ? [CPListItem(text: "Gerade ist niemand unterwegs", detailText: nil)]
            : friendItems,
            header: "Freunde", sectionIndexTitle: nil))
        return CPListTemplate(title: "Meeterz", sections: sections)
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
    private func go(to place: Place) {
        if AppModel.shared.navigation.isNavigating {
            Task { await AppModel.shared.navigation.addStop(place) }
        } else {
            preview(to: place.coordinate, name: place.name) {}
        }
    }

    // MARK: Fahrt-Panel (iOS 27): Ankunft unten angeheftet, Freunde zum Einladen darüber

    private var inviteDestination: Place? {
        AppModel.shared.navigation.destination ?? pendingDestination
    }

    /// Legt das Panel auf die Karten-Vorlage der laufenden Navigation
    @available(iOS 27.0, *)
    private func showTripPanel(on template: CPMapTemplate) {
        let model = AppModel.shared
        guard model.navigation.isNavigating, let place = inviteDestination else { return }
        let friends = model.friends.accepted
        guard !friends.isEmpty else { return }

        let items: [CPMapPanelItem] = friends.prefix(CPPanel.maximumPanelItemsCount).map { friend in
            CPMapPanelItem(
                routeDetails: [
                    CPRouteDetail(symbolName: "person.crop.circle.fill", value: friend.displayName),
                    CPRouteDetail(info: "Einladen"),
                ],
                handler: { [weak self] _, done in
                    self?.sendInvites(to: [friend.friendId], place: place)
                    done()
                }
            )
        }

        var buttons: CPMapPanelButtonConfiguration?
        if let remaining = model.navigation.remaining {
            let estimates = CPTravelEstimates(
                distanceRemaining: Measurement(value: remaining.distance, unit: .meters),
                timeRemaining: remaining.duration
            )
            let primary = CPTextButton(
                title: friends.count > 1 ? "Alle einladen" : "Einladen",
                textStyle: .confirm
            ) { [weak self] _ in
                self?.sendInvites(to: friends.map(\.friendId), place: place)
            }
            let toggle = CPButton(image: friendsToggleImage()) { [weak self] _ in
                guard let self else { return }
                friendsVisible.toggle()
                browseOverlay?.refresh()
                navigationOverlay?.refresh()
                if let current = manager.interfaceController?.topTemplate as? CPMapTemplate {
                    showTripPanel(on: current)   // Symbol aktualisieren
                }
            }
            buttons = CPMapPanelButtonConfiguration(primaryAction: primary, secondaryButton: toggle, travelEstimates: estimates)
        }

        let panel = CPMapPanel(
            title: "Einladen nach \(place.name)",
            sections: [CPMapPanelSection(title: "Freunde", items: items)],
            buttonConfiguration: buttons
        )
        panel.showsCloseButton = true
        template.showPanel(panel, completion: nil)
    }

    /// Fallback für iOS < 27: Freundesliste zum Einladen an das Fahrtziel
    private func showInviteList() {
        let model = AppModel.shared
        guard let place = inviteDestination else { return }
        let friends = model.friends.accepted
        guard !friends.isEmpty else { return }

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
        for friend in friends.prefix(max(0, CPListTemplate.maximumItemCount - items.count)) {
            let item = CPListItem(text: friend.displayName, detailText: "Einladen")
            item.handler = { [weak self] _, done in
                self?.sendInvites(to: [friend.friendId], place: place)
                self?.manager.interfaceController?.popTemplate(animated: true, completion: nil)
                done()
            }
            items.append(item)
        }
        let template = CPListTemplate(title: "Einladen nach \(place.name)", sections: [CPListSection(items: items)])
        manager.interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func friendsToggleImage() -> UIImage {
        let symbol = friendsVisible ? "person.2.fill" : "person.2.slash"
        return UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
            ?? UIImage()
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

    private func showSearch() {
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
            preview(to: place.coordinate, name: place.name, completion: completionHandler)
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
            let overlay = FriendOverlay(mapView: navigationMapView.mapView) { [weak self] in self?.friendsVisible ?? true }
            overlay.start()
            browseOverlay = overlay
            applyPitch(to: navigationMapView)
            browseRecenter?.cancel()
            browseRecenter = startAutoRecenter(navigationMapView)
            navigationMapView.navigationCamera.update(cameraState: .following)
            if CarPlayFlyoverMirror.isEnabled {
                let mirror = flyover ?? CarPlayFlyoverMirror { [weak self] in self?.friendsVisible ?? true }
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
            let overlay = FriendOverlay(mapView: mapView) { [weak self] in self?.friendsVisible ?? true }
            overlay.start()
            navigationOverlay = overlay
            if let navMap = navigationViewController.navigationMapView {
                applyPitch(to: navMap)
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
                guard let map = carPlayManager.carPlayMapViewController else { return nil }
                // Zentrieren auf den Live-Standort, Freunde ein/aus, Zoom
                return [map.recenterButton, friendsButton(), map.zoomInButton, map.zoomOutButton]
            case .navigating:
                // Kamera: folgen ↔ Übersicht, dazu 3D/2D (statt der Mapbox-Standardknöpfe)
                let camera = CPMapButton { [weak self] _ in
                    guard let camera = self?.manager.carPlayNavigationViewController?.navigationMapView?.navigationCamera else { return }
                    camera.update(cameraState: camera.currentCameraState == .following ? .overview : .following)
                }
                camera.image = UIImage(systemName: "location.viewfinder",
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
                let three = CPMapButton { [weak self] _ in self?.toggleThreeD() }
                three.image = Self.textImage(threeD ? "2D" : "3D")
                threeDMapButton = three
                return [camera, three]
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
            switch activity {
            case .browsing:
                // 3D/2D der Karte; während der Fahrt bleibt Mapbox-Standard (Stummschalten, Alternativen)
                let button = CPBarButton(title: threeD ? "2D" : "3D") { [weak self] _ in self?.toggleThreeD() }
                threeDBarButton = button
                return [button]
            default:
                return nil
            }
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
                let search = CPBarButton(title: "Suche") { [weak self] _ in self?.showSearch() }
                let goals = CPBarButton(title: "Ziele") { [weak self] _ in
                    guard let self else { return }
                    manager.interfaceController?.pushTemplate(destinationsTemplate(), animated: true, completion: nil)
                }
                return [search, goals]
            case .navigating:
                // „Beenden“ muss immer da sein (der Mapbox-Standardknopf entfällt, sobald wir die Leiste belegen).
                // Einladen öffnet nur auf Knopfdruck (ab iOS 27 als Panel, davor als Liste).
                let end = CPBarButton(title: "Beenden") { [weak self] _ in self?.endNavigationIfNeeded() }
                if !AppModel.shared.friends.accepted.isEmpty, inviteDestination != nil {
                    let invite = CPBarButton(title: "Einladen") { [weak self] _ in
                        guard let self else { return }
                        if #available(iOS 27.0, *), let map = manager.interfaceController?.topTemplate as? CPMapTemplate {
                            showTripPanel(on: map)
                        } else {
                            showInviteList()
                        }
                    }
                    return [invite, end]
                }
                return [end]
            case .previewing, .panningInBrowsingMode, .panningInNavigationMode:
                return nil
            }
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        templateDidAppear template: CPTemplate,
        animated: Bool
    ) {
        MainActor.assumeIsolated {
            // Das Einladen-Panel öffnet sich nicht mehr von selbst – nur über den Knopf „Einladen“
            _ = template
        }
    }

    nonisolated func carPlayManager(
        _ carPlayManager: CarPlayManager,
        selectedPreviewFor trip: CPTrip,
        using routeChoice: CPRouteChoice
    ) {
        MainActor.assumeIsolated { flyover?.showPreview(routeChoice.navigationRoutes) }
    }

    nonisolated func carPlayManagerDidCancelPreview(_ carPlayManager: CarPlayManager) {
        MainActor.assumeIsolated { flyover?.showPreview(nil) }
    }

    nonisolated func carPlayManagerDidBeginNavigation(_ carPlayManager: CarPlayManager) {
        MainActor.assumeIsolated {
            let coordinator = AppModel.shared.navigation
            if !coordinator.isNavigating {
                coordinator.didBeginOnCarPlay(destination: pendingDestination)
            }
        }
    }

    nonisolated func carPlayManagerDidEndNavigation(_ carPlayManager: CarPlayManager, byCanceling canceled: Bool) {
        MainActor.assumeIsolated {
            navigationOverlay?.stop()
            navigationOverlay = nil
            navRecenter?.cancel(); navRecenter = nil
            if let browseMap = carPlayManager.carPlayMapViewController?.navigationMapView {
                flyover?.attach(to: browseMap)
            }
            pendingDestination = nil
            AppModel.shared.navigation.stop()
        }
    }

    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, shouldPresentArrivalUIFor waypoint: Waypoint) -> Bool {
        true
    }
}
