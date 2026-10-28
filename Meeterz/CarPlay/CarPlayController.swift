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
import Contacts

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
    /// Bis wann keine Hinweise auf der Karte erscheinen (siehe alertTemplate)
    var alertsPausedUntil = Date.distantPast
    /// Ende der letzten Routenführung (Mitfahrer-Frage erst mit Abstand dazu)
    var navigationEndedAt = Date.distantPast
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
        get { Self.threeDEnabled }
        set { MapPreferences.setThreeD(newValue) }   // gemeinsam mit der iPhone-Karte
    }

    /// 2D/3D wurde umgeschaltet (hier oder auf dem iPhone): Kameras und Dashboard nachziehen
    func applyThreeD() {
        CarPlayDashboard.shared.applyMapType()   // Dashboard und Kombiinstrument folgen der Einstellung
        CarPlayDashboard.cluster.applyMapType()
        guard isConnected else { return }
        configureCamera(browseMap, navigating: false)
        configureCamera(navMap, navigating: true)
    }
    static var threeDEnabled: Bool { UserDefaults.standard.object(forKey: "carplay.3d") as? Bool ?? true }

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

    /// Neigung für 3D. MapKit (Flyover) übernimmt sie 1:1 von der Mapbox-Kamera; das Dashboard nutzt dieselbe.
    /// Vorher 65°: zusammen mit dem weiten Zoom auf der Autobahn sah man Horizont und Himmel (Fahrt am 27.10.).
    static let tilt3D: Double = 53

    /// Zoombereich während der Navigation. Mapbox zoomt weiter selbst (auf der Autobahn weiter heraus, vor Abbiegungen
    /// heran); manueller Zoom hat Vorrang. Mapbox' Vorgabe (ab 10,5) ging aber bis auf Stadtgröße – mit der Neigung
    /// sah man dann Himmel. Die Untergrenze 13,5 hält die Autobahn im Blick, ohne bis zum Horizont zu reichen.
    static let navigationZoomRange: ClosedRange<Double> = 13.5...17.5

    /// Zoom außerhalb der Fahrt (mit +/− gewählt, bleibt gespeichert)
    var browseZoom: Double {
        get { UserDefaults.standard.object(forKey: "carplay.zoom") as? Double ?? 16.5 }
        set { UserDefaults.standard.set(newValue, forKey: "carplay.zoom") }
    }

    /// Zoom der großen Karte gerade (Dashboard zeigt denselben Ausschnitt)
    var displayedZoom: Double {
        if let map = displayedMap, map.window != nil { return map.mapView.mapboxMap.cameraState.zoom }
        return browseZoom
    }

    /// Tag oder Nacht der großen Karte – Mapbox wählt das nach Sonnenstand und dem Erscheinungsbild von CarPlay.
    /// Das Dashboard übernimmt es (sein eigenes Fenster meldet immer „dunkel“).
    var mapStyleType: StyleType? { manager.carPlayMapViewController?.styleManager?.currentStyleType }

    /// Rand der Browse-Karte vor der Routenvorschau (danach wiederherstellen)
    private var previewPaddingBefore: UIEdgeInsets?

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
    func configureCamera(_ navigationMapView: NavigationMapView?, navigating: Bool) {
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
            options.followingCameraOptions.zoomRange = Self.navigationZoomRange
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

    /// Vor Abbiegungen/Ausfahrten näher heranzoomen (ManeuverGuidance). nil = Zoom wieder Mapbox überlassen.
    /// Ist die Karte schon so nah oder näher, bleibt sie, wie sie ist.
    private func setManeuverZoom(_ target: Double?) {
        guard navZoom == nil, let map = navMap,
              let source = map.navigationCamera.viewportDataSource as? CarPlayViewportDataSource else { return }
        var options = source.options
        var current = source.currentNavigationCameraOptions
        if let target {
            guard map.mapView.mapboxMap.cameraState.zoom < target - 0.1 else { return }
            options.followingCameraOptions.zoomUpdatesAllowed = false
            current.followingCamera.zoom = target
        } else {
            options.followingCameraOptions.zoomUpdatesAllowed = true
        }
        source.options = options
        source.currentNavigationCameraOptions = current
    }

    private func toggleThreeD() {
        lastMapInteraction = Date()
        threeD.toggle()   // zieht über applyThreeD() Kameras und Dashboard nach
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
                _ = self
                MapPreferences.setStyle(MapPreferences.Style(rawValue: key) ?? .satellite)   // gilt auch auf dem iPhone
                done()
                CarPlayUI.shared.pop(animated: true)
            }
            return item
        }
        func viewItem(_ three: Bool) -> CPListItem {
            let item = CPListItem(text: three ? "3D" : "2D", detailText: three ? String(localized: "Geneigt, mit Gebäuden") : String(localized: "Von oben"),
                                  image: UIImage(systemName: three ? "view.3d" : "map", withConfiguration: config),
                                  accessoryImage: threeD == three ? check : nil, accessoryType: .none)
            item.handler = { [weak self] _, done in
                if let self, threeD != three { toggleThreeD() }
                done()
                CarPlayUI.shared.pop(animated: true)
            }
            return item
        }
        let template = CPListTemplate(title: String(localized: "Kartenansicht"), sections: [
            CPListSection(items: [styleItem("satellite", String(localized: "Satellit"), "globe.europe.africa.fill"),
                                  styleItem("classic", String(localized: "Klassisch"), "map.fill"),
                                  styleItem("flyover", String(localized: "Apple Flyover (experimentell)"), "building.2.fill")],
                          header: String(localized: "Karte"), sectionIndexTitle: nil),
            CPListSection(items: [viewItem(true), viewItem(false)], header: String(localized: "Ansicht"), sectionIndexTitle: nil),
        ])
        CarPlayUI.shared.push(template, animated: true)
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
        AppModel.shared.startWithoutPhoneUI("CarPlay")
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
        startFreezeWatch()
        // Läuft auf dem iPhone schon eine Navigation, übernimmt CarPlay sie
        if AppModel.shared.navigation.isNavigating {
            beginNavigationIfConnected()
        }
    }

    func disconnect(scene: CPTemplateApplicationScene, interfaceController: CPInterfaceController, window: CPWindow) {
        DriveHealth.shared.stop()
        Passengers.shared.reset()   // Fahrt vorbei: Mitfahrer wieder sichtbar
        CarPlayUI.shared.reset()
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
        freezeWatch?.invalidate(); freezeWatch = nil
        isConnected = false
        // Freie Fahrt lief nur für die CarPlay-Karte (siehe NavigationCoordinator.stop) – ohne Route wieder anhalten
        AppModel.shared.navigation.idleIfUnused()
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
        pauseAlerts()   // Mapbox tauscht gleich die Ansicht
        manager.beginNavigationWithCarPlay(using: location.coordinate)
    }

    func endNavigationIfNeeded() {
        guard isConnected, manager.currentActivity == .navigating else { return }
        pauseAlerts()   // Mapbox tauscht gleich die Ansicht
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
            let item = CPListItem(text: meetup.placeName, detailText: String(localized: "Treffen mit \(meetup.incoming ? meetup.withText : meetup.otherName)"))
            item.handler = { [weak self] _, completion in
                self?.preview(to: meetup.coordinate, name: meetup.placeName, completion: completion)
            }
            return item
        }

        let friendItems: [CPListItem] = model.friendsOnMap.map { item in
            let route = model.routes.friendRoutes[item.friend.friendId]
            let detail = route.flatMap { r in r.destinationName.map { String(localized: "Unterwegs nach \($0)") } } ?? String(localized: "Zum aktuellen Standort")
            let listItem = CPListItem(text: item.friend.displayName, detailText: detail)
            listItem.handler = { [weak self] _, completion in
                self?.preview(to: item.position.coordinate, name: item.friend.displayName, completion: completion)
            }
            return listItem
        }

        let inviteItems: [CPListItem] = model.meetups.incomingPending.map { meetup in
            let item = CPListItem(text: meetup.placeName, detailText: String(localized: "Einladung von \(meetup.otherName)"))
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
                self?.preview(to: fav.coordinate, name: fav.label, address: fav.address, completion: completion)
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
                    self?.preview(to: recent.coordinate, name: recent.name, address: recent.address, completion: completion)
                }
                return item
            }

        var sections: [CPListSection] = []
        if !favoriteItems.isEmpty { sections.append(CPListSection(items: favoriteItems, header: String(localized: "Favoriten"), sectionIndexTitle: nil)) }
        if !recentItems.isEmpty { sections.append(CPListSection(items: recentItems, header: String(localized: "Zuletzt"), sectionIndexTitle: nil)) }
        if !inviteItems.isEmpty { sections.append(CPListSection(items: inviteItems, header: String(localized: "Einladungen"), sectionIndexTitle: nil)) }
        if !meetupItems.isEmpty { sections.append(CPListSection(items: meetupItems, header: String(localized: "Treffpunkte"), sectionIndexTitle: nil)) }
        sections.append(CPListSection(items: friendItems.isEmpty
            ? [CPListItem(text: String(localized: "Gerade ist niemand unterwegs"), detailText: nil)]
            : friendItems,
            header: String(localized: "Freunde"), sectionIndexTitle: nil))
        return CPListTemplate(title: String(localized: "Ziele"), sections: sections)
    }

    private func preview(to coordinate: CLLocationCoordinate2D, name: String, address: String? = nil,
                         completion: @escaping () -> Void) {
        let waypoint = Waypoint(coordinate: coordinate, name: name)
        pendingDestination = Place(id: UUID().uuidString, name: name, address: address, coordinate: coordinate)
        // Eigene Routenoptionen: Deutsch (sonst gilt die Systemsprache des iPhones, z. B. Englisch) und Auto
        // Mapbox meldet den Abschluss aus einem Hintergrund-Task; CarPlay bekommt ihn auf dem Hauptthread
        let completion = { DispatchQueue.main.async(execute: completion) }
        guard let here = AppModel.shared.location.lastLocation else {
            manager.previewRoutes(to: waypoint, completionHandler: completion)
            return
        }
        let options = NavigationRouteOptions(
            waypoints: [Waypoint(location: here, name: String(localized: "Aktueller Standort")), waypoint],
            profileIdentifier: .automobileAvoidingTraffic,
            locale: Locale.navigation,
            distanceUnit: .kilometer)
        RoutePreferences.apply(to: options)
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
                CarPlayUI.shared.popToRoot(animated: true)
                done()
            }
            return
        }
        CarPlayUI.shared.popToRoot(animated: true)
        done()
        showLoading(at: place)
        preview(to: place.coordinate, name: place.name, address: place.address) { [weak self] in
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
    /// Die einzeln gezeigten Routen der aktuellen Vorschau (Pfeile zum Blättern)
    private var splitTrips: [CPTrip] = []

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
            CarPlayUI.shared.popToRoot(animated: false)
            showLoading(at: place)
        }
        preview(to: place.coordinate, name: place.name, address: place.address) { [weak self] in
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
        pauseAlerts()   // Mapbox tauscht gleich die Ansicht
        manager.mapTemplate(template, startedTrip: trip, using: choice)
    }

    // MARK: Sprachansagen (Alle / Nur Warnungen / Aus)

    private func voiceButton() -> CPBarButton {
        let mode = MeeterzSpeechSynthesizer.shared.mode
        let image = UIImage(systemName: mode.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
            ?? UIImage()
        return CPBarButton(image: image) { [weak self] _ in
            MeeterzSpeechSynthesizer.shared.mode = MeeterzSpeechSynthesizer.shared.mode.next
            self?.refreshVoiceButton()
            self?.showVoiceModeHint()
        }
    }

    /// Knopf nach einem Wechsel (auch vom iPhone aus) neu setzen – CarPlay-Knöpfe lassen sich nicht ändern
    func refreshVoiceButton() {
        guard isConnected, manager.currentActivity == .navigating,
              let template = manager.interfaceController?.rootTemplate as? CPMapTemplate else { return }
        template.leadingNavigationBarButtons = [voiceButton()]
    }

    /// Kurz anzeigen, was jetzt gilt (das Symbol allein ist im Auto schwer zu lesen)
    private func showVoiceModeHint() {
        let alert = CPNavigationAlert(titleVariants: [MeeterzSpeechSynthesizer.shared.mode.title], subtitleVariants: [],
                                      image: nil, primaryAction: CPAlertAction(title: String(localized: "OK"), style: .default) { _ in },
                                      secondaryAction: nil, duration: 2)
        _ = CarPlayUI.shared.alert(alert, replacing: true)   // über die Warteschlange (nie zwei Hinweise gleichzeitig)
    }

    // MARK: Stehende Karte erkennen (nur Protokoll)

    /// „Die große Karte bleibt komplett stehen“ ist kein Hänger des Hauptthreads (den meldet der StallLogger) –
    /// die App läuft weiter, nur die Kamera der sichtbaren Karte bewegt sich nicht. Darum hier gesondert: fährt das
    /// Auto (> 15 km/h), die Kamera steht aber seit 15 s still, einmal festhalten, welcher Zustand vorliegt.
    private var freezeWatch: Timer?
    private var frozenSince: Date?
    private var lastCameraKey = ""
    private var freezeLogged = false

    private func startFreezeWatch() {
        freezeWatch?.invalidate()
        freezeWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFreeze() }
        }
    }

    private func checkFreeze() {
        guard let loc = AppModel.shared.location.lastLocation, loc.speed > 4,
              Date().timeIntervalSince(loc.timestamp) < 10,
              let map = displayedMap, let cam = map.mapView.mapboxMap?.cameraState,
              // Nur zählen, solange die große Karte wirklich vorn ist: Liegt das Dashboard oder eine andere App vorn,
              // zeichnet Mapbox (zu Recht) nicht weiter – das meldete am 28.10. viele falsche „Karte steht“.
              map.window?.windowScene?.activationState == .foregroundActive else {
            frozenSince = nil; freezeLogged = false; return
        }
        let key = String(format: "%.5f,%.5f,%.1f", cam.center.latitude, cam.center.longitude, cam.bearing)
        // Auch eine Flyover-Karte ohne neue Bilder zählt als stehend, selbst wenn Mapbox darunter weiterläuft
        let flyoverStale = (flyover?.frameAge ?? 0) > 5
        if key != lastCameraKey && !flyoverStale {
            lastCameraKey = key
            if freezeLogged { Diag.log("CarPlay: Karte bewegt sich wieder") }
            frozenSince = nil; freezeLogged = false
            return
        }
        let since = frozenSince ?? Date()
        frozenSince = since
        guard !freezeLogged, Date().timeIntervalSince(since) > 15 else { return }
        freezeLogged = true
        let isNav = map === navMap
        let camState = map.navigationCamera.currentCameraState
        Diag.log("CarPlay: Karte steht seit \(Int(Date().timeIntervalSince(since))) s bei \(Int(loc.speed * 3.6)) km/h – sichtbar: \(isNav ? "Navigation" : "Browse"), Aktivität: \(String(describing: manager.currentActivity)), Kamera: \(camState), Navigation läuft (App): \(AppModel.shared.navigation.isNavigating), Flyover: \(flyover?.diagnostics ?? "aus")")
    }

    // MARK: Kartenstil sofort wechseln (Einstellung „Karte in CarPlay“)

    func applyMapStyle() {
        guard isConnected else { return }
        let satellite = UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true
        manager.styles = NavigationStyles.carPlay()
        for map in [browseMap, navMap].compactMap({ $0 }) {
            Satellite3DBuildings.install(on: map.mapView, satellite: satellite)
        }
        // Die Karte, die gerade wirklich im Fenster ist. Vorher entschied `currentActivity`: meldete CarPlay während der
        // Fahrt etwas anderes als `.navigating`, hängte sich Flyover an die verdeckte Browse-Karte (ohne Fenster) –
        // und blieb unsichtbar, bis zufällig ein anderer Weg neu einhängte (Fahrt am 27.10.: 7 Minuten).
        let current = displayedMap
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
            titleVariants: [String(localized: "\(meetup.otherName) lädt dich ein: \(meetup.placeName)"), String(localized: "\(meetup.otherName) lädt dich ein")],
            actions: [
                CPAlertAction(title: String(localized: "Annehmen"), style: .default) { [weak self] _ in
                    CarPlayUI.shared.dismiss(animated: true)
                    Task { @MainActor in
                        await AppModel.shared.meetups.respond(meetup, accept: true)
                        self?.go(to: meetup.place)
                    }
                },
                CPAlertAction(title: String(localized: "Ablehnen"), style: .cancel) { [weak self] _ in
                    CarPlayUI.shared.dismiss(animated: true)
                    Task { @MainActor in await AppModel.shared.meetups.respond(meetup, accept: false) }
                },
            ]
        )
        CarPlayUI.shared.present(alert, animated: true)
    }

    /// Läuft schon eine Navigation, wird der Ort Zwischenstopp, sonst Routenvorschau
    func go(to place: Place) {
        if AppModel.shared.navigation.isNavigating {
            Task { await AppModel.shared.navigation.addStop(place) }
        } else {
            preview(to: place.coordinate, name: place.name, address: place.address) {}
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

        let stop = CPListItem(text: String(localized: "Stopp hinzufügen"), detailText: nil,
                              image: UIImage(systemName: "plus.circle.fill"))
        stop.handler = { [weak self] _, done in
            CarPlayUI.shared.pop(animated: false)
            self?.showSearchHub()
            done()
        }
        var sections: [CPListSection] = []
        // Kurz Bescheid geben: an alle, die ich hier treffe oder die auch hierher fahren
        let partners = meetupPartners(at: place)
        if !partners.ids.isEmpty {
            let names = partners.ids.compactMap { model.friend($0)?.displayName.split(separator: " ").first.map(String.init) }
            let tell = CPListItem(text: String(localized: "Kurz Bescheid geben"), detailText: String(localized: "an ") + names.joined(separator: ", "),
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
            let all = CPListItem(text: String(localized: "Alle einladen"), detailText: nil)
            all.handler = { [weak self] _, done in
                self?.sendInvites(to: friends.map(\.friendId), place: place)
                CarPlayUI.shared.pop(animated: true)
                done()
            }
            items.append(all)
        }
        for friend in friends.prefix(max(0, CPListTemplate.maximumItemCount - items.count - 4)) {
            let detail = friendArrival(friend.friendId, at: place).map { String(localized: "Kommt auch hierher · an \(Format.time.string(from: $0))") } ?? String(localized: "Einladen")
            let item = CPListItem(text: friend.displayName, detailText: detail)
            item.handler = { [weak self] _, done in
                self?.sendInvites(to: [friend.friendId], place: place)
                CarPlayUI.shared.pop(animated: true)
                done()
            }
            items.append(item)
        }
        if !items.isEmpty { sections.append(CPListSection(items: items, header: String(localized: "Einladen"), sectionIndexTitle: nil)) }
        let template = CPListTemplate(title: place.name, sections: sections)
        CarPlayUI.shared.push(template, animated: true)
    }

    private func sendInvites(to ids: [UUID], place: Place) {
        Task { @MainActor in
            var sent = 0
            for id in ids where await AppModel.shared.meetups.propose(to: id, place: place, silent: true) { sent += 1 }
            showNotice(sent == 0 ? String(localized: "Einladung fehlgeschlagen.")
                                 : sent == 1 ? String(localized: "Einladung gesendet.") : String(localized: "\(sent) Einladungen gesendet."))
        }
    }

    private func showNotice(_ text: String) {
        guard let controller = manager.interfaceController, controller.presentedTemplate == nil else { return }
        let alert = CPAlertTemplate(titleVariants: [text], actions: [
            CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                CarPlayUI.shared.dismiss(animated: true)
            }
        ])
        CarPlayUI.shared.present(alert, animated: true)
    }

    // MARK: Suche (Tastatur im Stand, Diktat beim Fahren – das entscheidet CarPlay selbst)

    func showSearch() {
        Diag.log("CarPlay-Suche geöffnet, vom Auto gesperrt: \(Self.describe(session?.limitedUserInterfaces ?? []))")
        let template = CPSearchTemplate()
        template.delegate = self
        CarPlayUI.shared.push(template, animated: true)
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
            let shown = Self.withRouteOptions(Self.withBatteryForecast(Self.withPhoneLabels(trip, destination: pendingDestination)))
            previewTrip = shown
            return shown
        }
    }

    /// Routenauswahl wie auf dem iPhone. Die Karte für die gewählte Route zeigt CarPlay selbst mit Ankunft, Dauer und
    /// Strecke – darum dort nur noch „Schnellste“ / „Alternative 1“ (und Akku/Optionen), nicht noch einmal Dauer und
    /// Strecke (stand doppelt und wich durch andere Rundung ab: „45 Min · 41,5 km“ über „44 Min. · 41 km“).
    /// In der Liste aller Routen steht die Dauer/Strecke als Titel, damit man sie vergleichen kann.
    /// Unter dem Zielnamen stand außerdem noch einmal der Name („Arbeit“ / „Arbeit“): Das Ziel bekommt seine Adresse.
    private static func withPhoneLabels(_ trip: CPTrip, destination: Place?) -> CPTrip {
        let choices = trip.routeChoices.enumerated().map { index, choice -> CPRouteChoice in
            guard let route = mainRoute(in: choice.userInfo) else { return choice }
            let label = index == 0 ? String(localized: "Schnellste") : String(localized: "Alternative \(index)")
            let detail = "\(Format.minutes(seconds: route.expectedTravelTime)) · \(Format.distance(route.distance))"
            let copy = CPRouteChoice(summaryVariants: [detail],
                                     additionalInformationVariants: [label],
                                     selectionSummaryVariants: [label])
            copy.userInfo = choice.userInfo
            return copy
        }
        var target = trip.destination
        if let destination, let address = destination.address, !address.isEmpty,
           destination.coordinate.distance(to: trip.destination.placemark.coordinate) < 200 {
            let placemark = MKPlacemark(coordinate: trip.destination.placemark.coordinate,
                                        addressDictionary: [CNPostalAddressStreetKey: address])
            target = MKMapItem(placemark: placemark)
            target.name = destination.name
        }
        let copy = CPTrip(origin: trip.origin, destination: target, routeChoices: choices)
        copy.userInfo = trip.userInfo
        return copy
    }

    /// „ohne Maut“ unter jeder Routen-Option, wenn Routenoptionen aktiv sind
    private static func withRouteOptions(_ trip: CPTrip) -> CPTrip {
        guard let summary = RoutePreferences.summary else { return trip }
        let choices = trip.routeChoices.map { choice -> CPRouteChoice in
            let info = (choice.additionalInformationVariants ?? []).map { "\($0) · \(summary)" }
            let copy = CPRouteChoice(summaryVariants: choice.summaryVariants,
                                     additionalInformationVariants: info.isEmpty ? [summary] : info,
                                     selectionSummaryVariants: choice.selectionSummaryVariants ?? [])
            copy.userInfo = choice.userInfo
            return copy
        }
        let copy = CPTrip(origin: trip.origin, destination: trip.destination, routeChoices: choices)
        copy.userInfo = trip.userInfo
        return copy
    }

    /// Zuletzt berechnete Prognosen je Route (Schlüssel: Länge + Fahrzeit + Akkustand)
    private static var forecastCache: [String: String] = [:]

    /// E-Auto: unter jeder Routen-Option „Ankunft mit 54 %“ bzw. „1 Ladestopp · Ankunft 21 %“.
    /// Mapbox wartet synchron auf diese Antwort, und CarPlay friert so lange ein. Darum wird im Hintergrund
    /// gerechnet und höchstens 0,4 s gewartet. Ist es bis dahin nicht fertig (lange Route, Ladesäulen noch nicht
    /// eingelesen), erscheint die Vorschau ohne Prognose. Das Ergebnis landet im Zwischenspeicher für die nächste Vorschau.
    private static func withBatteryForecast(_ trip: CPTrip) -> CPTrip {
        guard EVSettings.enabled, let vehicle = EVSettings.vehicle else { return trip }
        let settings = EVSettings.plannerSettings
        let start = EVSettings.chargePercent
        let routes = trip.routeChoices.map { mainRoute(in: $0.userInfo) }
        let keys = routes.map { r in r.map { "\(Int($0.distance))-\(Int($0.expectedTravelTime))-\(Int(start))" } }
        let missing = zip(routes, keys).compactMap { r, k -> (Route, String)? in
            guard let r, let k, forecastCache[k] == nil else { return nil }
            return (r, k)
        }
        if !missing.isEmpty {
            let done = DispatchSemaphore(value: 0)
            let box = ForecastBox()
            Task.detached(priority: .userInitiated) {
                var texts: [String: String] = [:]
                for (route, key) in missing {
                    let text: String
                    switch ChargePlanner.plan(route: route, vehicle: vehicle, startPercent: start, settings: settings, sites: ChargeSites.all) {
                    case .success(let plan) where plan.direct: text = String(localized: "Ankunft mit \(Int(plan.arrivalPercent.rounded())) %")
                    case .success(let plan): text = (plan.stops.count == 1 ? String(localized: "1 Ladestopp") : String(localized: "\(plan.stops.count) Ladestopps")) + " · " + String(localized: "Ankunft \(Int(plan.arrivalPercent.rounded())) %")
                    case .failure: text = String(localized: "Akku reicht nicht – kein Ladeplan")
                    }
                    texts[key] = text
                }
                box.set(texts)
                done.signal()
                // Kam es zu spät, steht es so bei der nächsten Vorschau bereit
                let result = texts
                await MainActor.run { forecastCache.merge(result) { $1 } }
            }
            if done.wait(timeout: .now() + 0.4) == .timedOut {
                Diag.log("Akku-Prognose in der Vorschau ausgelassen (Berechnung > 0,4 s)")
                return trip
            }
            forecastCache.merge(box.get()) { $1 }
        }
        var changed = false
        let choices: [CPRouteChoice] = zip(trip.routeChoices, keys).map { choice, key in
            guard let key, let text = forecastCache[key] else { return choice }
            changed = true
            let info = (choice.additionalInformationVariants ?? []).map { "\($0) · \(text)" }
            let copy = CPRouteChoice(summaryVariants: choice.summaryVariants,
                                     additionalInformationVariants: info.isEmpty ? [text] : info,
                                     selectionSummaryVariants: choice.selectionSummaryVariants ?? [])
            copy.userInfo = choice.userInfo
            return copy
        }
        if forecastCache.count > 30 { forecastCache = [:] }
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
            titleVariants: [String(localized: "Route konnte nicht berechnet werden"), String(localized: "Keine Route")],
            subtitleVariants: [String(localized: "Prüfe die Internetverbindung und versuche es erneut.")],
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
            navigationMapView.navigationCamera.cameraStateTransition = SmoothCameraTransition(navigationMapView.mapView)
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
            pauseAlerts()
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
                let transition = SmoothCameraTransition(navMap.mapView)
                transition.zoomPinned = { [weak self] in
                    MainActor.assumeIsolated { self?.navZoom != nil || ManeuverGuidance.shared.isZoomed }
                }
                navMap.navigationCamera.cameraStateTransition = transition
                configureCamera(navMap, navigating: true)
                autoHideButtons()
                navRecenter?.cancel()
                navRecenter = startAutoRecenter(navMap)
                ManeuverGuidance.shared.applyZoom = { [weak self] zoom in self?.setManeuverZoom(zoom) }
                ManeuverGuidance.shared.userZoomed = { [weak self] in self?.navZoom != nil }
                ManeuverGuidance.shared.start(navigationViewController)
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
            // Links bleibt die Leiste frei (2D/3D sitzt rechts bei den Kartenknöpfen).
            // Während der Fahrt nur der Ansagen-Knopf wie bei Apple Karten. Mapbox' „Alternativen“ entfällt: nach dem
            // Start gab es dort praktisch nie eine Auswahl („Keine alternativen Routen“); schnellere Routen bieten wir
            // ohnehin per Hinweis an.
            switch activity {
            case .browsing: return []
            case .navigating: return [voiceButton()]
            default: return nil
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
                let search = CPBarButton(title: String(localized: "Suche")) { [weak self] _ in self?.showSearchHub() }
                let goals = CPBarButton(title: String(localized: "Ziele")) { [weak self] _ in
                    guard let self else { return }
                    CarPlayUI.shared.push(destinationsTemplate(), animated: true)
                }
                return [search, goals]
            case .navigating:
                // „Beenden“ muss immer da sein (der Mapbox-Standardknopf entfällt, sobald wir die Leiste belegen).
                // Kein dauerhaftes Fenster über der Karte – Einladen und Stopp öffnen sich nur auf Knopfdruck.
                let end = CPBarButton(title: String(localized: "Beenden")) { [weak self] _ in self?.endNavigationIfNeeded() }
                if inviteDestination != nil, !AppModel.shared.friends.accepted.isEmpty || EVSettings.enabled {
                    let more = CPBarButton(title: String(localized: "Mehr")) { [weak self] _ in self?.showInviteList() }
                    return [more, end]
                }
                let stop = CPBarButton(title: String(localized: "Stopp")) { [weak self] _ in self?.showSearchHub() }
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
            splitRoutesIfNeeded(trip)
            framePreview(routeChoice.navigationRoutes)
            flyover?.showPreview(routeChoice.navigationRoutes)
            refreshFriends()
        }
    }

    /// Mehrere Routen: je Route eine eigene Vorschau, zwischen denen man mit den Pfeilen der Auswahlkarte blättert
    /// („1 von 3“) – so wie in einer Liste untereinander, aber ohne dass die Karte verdeckt wird. Die eingebettete
    /// Routenliste wie bei Apple Karten bekommen andere Apps von CarPlay nicht.
    private func splitRoutesIfNeeded(_ trip: CPTrip) {
        guard trip.routeChoices.count > 1, !splitTrips.contains(where: { $0 === trip }),
              let template = manager.interfaceController?.topTemplate as? CPMapTemplate else { return }
        let trips = trip.routeChoices.map { choice -> CPTrip in
            let single = CPTrip(origin: trip.origin, destination: trip.destination, routeChoices: [choice])
            single.userInfo = trip.userInfo
            return single
        }
        splitTrips = trips
        let text = CPTripPreviewTextConfiguration(startButtonTitle: String(localized: "Starten"),
                                                  additionalRoutesButtonTitle: nil, overviewButtonTitle: nil)
        template.showTripPreviews(trips, selectedTrip: trips.first, textConfiguration: text)
        for (single, choice) in zip(trips, trip.routeChoices) {
            guard let route = Self.mainRoute(in: choice.userInfo) else { continue }
            template.updateEstimates(CPTravelEstimates(distanceRemaining: Measurement(value: route.distance, unit: UnitLength.meters),
                                                       timeRemaining: route.expectedTravelTime), for: single)
        }
        Diag.log("Routenvorschau: \(trips.count) Routen zum Blättern")
    }

    nonisolated func carPlayManagerDidCancelPreview(_ carPlayManager: CarPlayManager) {
        MainActor.assumeIsolated {
            splitTrips = []
            framePreview(nil)
            flyover?.showPreview(nil)
            refreshFriends()
        }
    }

    /// Routenvorschau so rahmen, dass CarPlays Auswahlkarte (links) die Routen nicht verdeckt. Mapbox rahmte über die
    /// ganze Breite – die Routen lagen zur Hälfte unter der Karte. Dazu „+2 Min“ an den Alternativen wie Apple Karten.
    private func framePreview(_ routes: NavigationRoutes?) {
        guard let map = browseMap else { return }
        if previewPaddingBefore == nil { previewPaddingBefore = map.viewportPadding }
        guard let routes else {
            if let before = previewPaddingBefore { map.viewportPadding = before }
            previewPaddingBefore = nil
            return
        }
        let w = map.bounds.width, h = map.bounds.height
        let panel = w > h ? max(w * 0.42, 260) : 0
        let safe = map.mapView.safeAreaInsets
        // Meldet CarPlay die Auswahlkarte schon über den sicheren Bereich, nichts doppelt abziehen
        let left = max(0, panel - safe.left) + 24
        map.viewportPadding = UIEdgeInsets(top: 30, left: left, bottom: 30, right: 30)
        map.showcase(routes, routeAnnotationKinds: [.relativeDurationsOnAlternative], animated: true, duration: 0.5)
        Diag.log("Routenvorschau: \(Int(w))×\(Int(h)), sicherer Bereich links \(Int(safe.left)), Rand links \(Int(left))")
    }

    nonisolated func carPlayManagerDidBeginNavigation(_ carPlayManager: CarPlayManager) {
        MainActor.assumeIsolated {
            framePreview(nil)
            pauseAlerts()
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
            Diag.log("CarPlay: Navigation beendet (\(canceled ? "abgebrochen" : "am Ziel")), Browse-Karte im Fenster: \(carPlayManager.carPlayMapViewController?.navigationMapView.window != nil), Flyover: \(flyover != nil)")
            pauseAlerts()
            navigationEndedAt = Date()
            navigationOverlay?.stop()
            navigationOverlay = nil
            navRecenter?.cancel(); navRecenter = nil
            ManeuverGuidance.shared.stop()
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

    /// Ankunft: Mapbox blendet dafür eine Auswahl ein (schließt eine offene, öffnet sofort die neue – ohne auf CarPlay
    /// zu warten, an unserer Warteschlange vorbei). Am Ziel beenden wir die Navigation stattdessen direkt (ohne
    /// Klick und ohne Feedback-Frage). Am Zwischenziel (Ladestopp) zeigen wir einen eigenen, kurzen Hinweis über die
    /// Warteschlange – der verdeckt auch die Ladeanzeige nicht, bis man „Weiter“ tippt.
    nonisolated func carPlayManager(_ carPlayManager: CarPlayManager, shouldPresentArrivalUIFor waypoint: Waypoint) -> Bool {
        MainActor.assumeIsolated {
            let final = AppModel.shared.navigation.destination.map { $0.coordinate.distance(to: waypoint.coordinate) < 150 } ?? true
            if final {
                // Am Ziel: Navigation direkt beenden – ohne Auswahl „Navigation beenden / Fahrt bewerten“
                Diag.log("Ziel erreicht – Navigation beendet")
                pauseAlerts()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))   // Mapbox die Ankunftsansage zu Ende bringen lassen
                    guard let self, self.manager.currentActivity == .navigating else { return }
                    self.pauseAlerts()
                    self.manager.carPlayNavigationViewController?.exitNavigation(byCanceling: false)
                }
                return false
            }
            presentStopArrival(waypoint)
            return false
        }
    }

    private func presentStopArrival(_ waypoint: Waypoint) {
        let stop = ChargingSession.shared.plan?.stops.first { $0.site.coordinate.distance(to: waypoint.coordinate) < 300 }
        let title = stop.map { String(localized: "Ladestopp erreicht: \($0.site.title)") } ?? String(localized: "Angekommen: \(waypoint.name ?? String(localized: "Zwischenziel"))")
        let subtitle = stop.map { String(localized: "Laden bis \(Int($0.departurePercent.rounded(.up)) + 1) % · ca. \(Int(($0.chargeTime / 60).rounded())) Min.") }
        Diag.log(title)
        Task { @MainActor in
            guard await self.waitForAlertSlot(timeout: 20) else { return }
            let ok = CPAlertAction(title: "OK", style: .cancel) { _ in }
            let alert = CPNavigationAlert(titleVariants: [title], subtitleVariants: subtitle.map { [$0] },
                                          image: UIImage(systemName: stop != nil ? "bolt.car.fill" : "mappin.circle.fill"),
                                          primaryAction: ok, secondaryAction: nil, duration: 10)
            CarPlayUI.shared.alert(alert)
        }
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
        if limits.contains(.keyboard) { parts.append(String(localized: "Tastatur")) }
        if limits.contains(.lists) { parts.append(String(localized: "Listen")) }
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

/// Ergebnis der Vorschau-Prognose zwischen Hintergrund und wartendem Hauptthread
private final class ForecastBox: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String: String] = [:]
    func set(_ t: [String: String]) { lock.lock(); texts = t; lock.unlock() }
    func get() -> [String: String] { lock.lock(); defer { lock.unlock() }; return texts }
}
