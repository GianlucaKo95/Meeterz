import UIKit
import CarPlay
import Combine
import CoreLocation
import MapKit
import MapboxMaps
import MapboxNavigationCore
import MapboxNavigationUIKit

/// Dashboard-Karte im CarPlay-Startbildschirm: eigene Karte mit Standort, Freunden und der laufenden Route,
/// damit dort nicht die Karte eines anderen Navi-Programms steht.
final class CarPlayDashboardSceneDelegate: NSObject, CPTemplateApplicationDashboardSceneDelegate {
    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        MainActor.assumeIsolated {
            MainThreadWatch.start(label: "Dashboard")
            Diag.log("Dashboard verbunden: Fenster \(Int(window.bounds.width))x\(Int(window.bounds.height)), Szene=\(templateApplicationDashboardScene.activationState.rawValue)")
            AppModel.shared.startWithoutPhoneUI("Dashboard")
            CarPlayDashboard.shared.connect(window: window)
            CarPlayDashboard.shared.dashboardController = dashboardController
            CarPlayDashboard.shared.scene = templateApplicationDashboardScene
            CarPlayDashboard.shared.updateShortcuts()
        }
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        MainActor.assumeIsolated {
            Diag.log("Dashboard getrennt")
            CarPlayDashboard.shared.disconnect()
        }
    }

    // Diagnose: wird die Dashboard-Szene je aktiv?
    func sceneDidBecomeActive(_ scene: UIScene) {
        MainActor.assumeIsolated {
            Diag.log("Dashboard-Szene: aktiv")
            CarPlayDashboard.shared.sceneDidActivate()
        }
    }
    func sceneWillResignActive(_ scene: UIScene) { MainActor.assumeIsolated { Diag.log("Dashboard-Szene: wird inaktiv") } }
    func sceneWillEnterForeground(_ scene: UIScene) { MainActor.assumeIsolated { Diag.log("Dashboard-Szene: Vordergrund") } }
    func sceneDidEnterBackground(_ scene: UIScene) { MainActor.assumeIsolated { Diag.log("Dashboard-Szene: Hintergrund (\(Self.context))") } }

    /// Wer hat die Dashboard-Szene in den Hintergrund geschickt? Zustand aller Szenen und ob das iPhone gesperrt ist
    @MainActor static var context: String {
        let app = UIApplication.shared
        let scenes = app.connectedScenes.map { scene -> String in
            let role = scene.session.role.rawValue.replacingOccurrences(of: "UIWindowSceneSessionRole", with: "")
                .replacingOccurrences(of: "CPTemplateApplication", with: "CP")
            let state: String
            switch scene.activationState {
            case .foregroundActive: state = "aktiv"
            case .foregroundInactive: state = "inaktiv"
            case .background: state = "Hintergrund"
            default: state = "getrennt"
            }
            return "\(role)=\(state)"
        }.sorted().joined(separator: ", ")
        return "iPhone gesperrt: \(app.isProtectedDataAvailable ? "nein" : "ja"), Szenen: \(scenes)"
    }
}

/// Misst nach dem Verbinden mit CarPlay 60 s lang, ob der Hauptthread hängt (Dashboard wartet sonst auf uns)
enum MainThreadWatch {
    static func start(label: String) {
        let queue = DispatchQueue(label: "meeterz.mainwatch")
        queue.async {
            let end = Date().addingTimeInterval(60)
            var worst: TimeInterval = 0
            while Date() < end {
                let sent = Date()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                _ = done.wait(timeout: .now() + 5)
                let delay = Date().timeIntervalSince(sent)
                if delay > 0.5 { Diag.log("\(label): Hauptthread \(String(format: "%.1f", delay)) s blockiert") }
                worst = max(worst, delay)
                Thread.sleep(forTimeInterval: 0.25)
            }
            Diag.log("\(label): Hauptthread in 60 s maximal \(String(format: "%.2f", worst)) s blockiert")
        }
    }
}

/// Karte im Kombiinstrument (Tacho), falls das Auto das unterstützt. Abbiegehinweise blendet das Auto
/// selbst aus der laufenden Navigation ein; wir liefern die Karte darunter.
final class CarPlayClusterSceneDelegate: NSObject, CPTemplateApplicationInstrumentClusterSceneDelegate,
                                          CPInstrumentClusterControllerDelegate {
    func templateApplicationInstrumentClusterScene(
        _ templateApplicationInstrumentClusterScene: CPTemplateApplicationInstrumentClusterScene,
        didConnect instrumentClusterController: CPInstrumentClusterController
    ) {
        MainActor.assumeIsolated {
            instrumentClusterController.delegate = self
            instrumentClusterController.inactiveDescriptionVariants = ["Meeterz"]
            Diag.log("CarPlay: Kombiinstrument verbunden")
        }
    }

    func templateApplicationInstrumentClusterScene(
        _ templateApplicationInstrumentClusterScene: CPTemplateApplicationInstrumentClusterScene,
        didDisconnectInstrumentClusterController instrumentClusterController: CPInstrumentClusterController
    ) {
        MainActor.assumeIsolated { CarPlayDashboard.cluster.disconnect() }
    }

    func instrumentClusterControllerDidConnect(_ instrumentClusterWindow: UIWindow) {
        MainActor.assumeIsolated { CarPlayDashboard.cluster.connect(window: instrumentClusterWindow, zoom: 16.5) }
    }

    func instrumentClusterControllerDidDisconnectWindow(_ instrumentClusterWindow: UIWindow) {
        MainActor.assumeIsolated { CarPlayDashboard.cluster.disconnect() }
    }

    func instrumentClusterControllerDidZoom(in instrumentClusterController: CPInstrumentClusterController) {
        MainActor.assumeIsolated { CarPlayDashboard.cluster.zoom(by: 1) }
    }

    func instrumentClusterControllerDidZoomOut(_ instrumentClusterController: CPInstrumentClusterController) {
        MainActor.assumeIsolated { CarPlayDashboard.cluster.zoom(by: -1) }
    }
}

/// Dashboard- und Kombiinstrument-Karte – dieselbe Karte wie die große CarPlay-Ansicht:
/// Mapbox bei „Satellit“ und „Klassisch“ (gleicher Stil, gleiche Kamera, gleiche Neigung und gleicher Zoom),
/// Apple MapKit bei „Flyover“ (wie die Flyover-Ebene über der großen Karte).
///
/// Früher lief hier immer eine Mapbox-Karte. Mapbox zeichnet nur, solange es die Szene als aktiv erkennt;
/// die Dashboard-Szene meldet sich beim Verbinden aber als „nicht verbunden“ (Diagnose: Szene=-1).
/// Die Karte lud laut Diagnose, wurde aber sehr wahrscheinlich nie gezeichnet – CarPlay zeigte nur das
/// App-Symbol und das Dashboard hing. MapKit hängt nicht an dieser Erkennung.
@MainActor
final class CarPlayDashboard: NSObject, MKMapViewDelegate {
    static let shared = CarPlayDashboard(name: "Dashboard")
    /// Dieselbe Karte im Kombiinstrument
    static let cluster = CarPlayDashboard(name: "Kombiinstrument")

    private let name: String
    private var mapView: MKMapView?
    /// Schnellwahl-Knöpfe im Dashboard (ohne laufende Navigation)
    var dashboardController: CPDashboardController?
    weak var scene: CPTemplateApplicationDashboardScene?
    private var distance: CLLocationDistance = 900
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var connectedAt = Date()
    private var renderedLogged = false
    private var pins: [UUID: MapPin] = [:]
    private var routeOverlays: [MKOverlay] = []

    // Mapbox-Variante (Satellit/Klassisch)
    private var mapbox: NavigationMapView?
    private var mapboxOverlay: FriendOverlay?
    private var container: DashboardContainer?
    private weak var window: UIWindow?
    private var zoomLevel = 15.5
    /// Kombiinstrument: eigener Zoom (+/− am Lenkrad); Dashboard: derselbe Zoom wie die große Karte
    private var ownZoom: Double?
    private var mapboxRendered = false
    private var mapboxTokens = Set<AnyCancelable>()

    /// Nächster Zoom im Dashboard (wie die Navigation höchstens)
    static let maxZoom = CarPlayController.navigationZoomRange.upperBound

    /// Welche Karte gerade gilt: wie die große CarPlay-Karte
    private static var usesMapbox: Bool { !CarPlayFlyoverMirror.isEnabled }

    private init(name: String) {
        self.name = name
        super.init()
    }

    func connect(window: UIWindow, zoom: Double = 15.5) {
        disconnect()
        self.window = window
        zoomLevel = zoom
        ownZoom = name == "Kombiinstrument" ? zoom : nil
        connectedAt = Date()
        if Self.usesMapbox { connectMapbox(window: window) } else { connectMapKit(window: window, zoom: zoom) }
    }

    private func connectMapKit(window: UIWindow, zoom: Double) {
        // Zoomstufe grob in Kameraabstand umrechnen (16 ≈ 700 m)
        distance = 700 * pow(2, 16 - zoom)

        let map = MKMapView(frame: window.bounds)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = self
        Self.applyStyle(to: map)
        map.overrideUserInterfaceStyle = CarPlayController.shared.mapStyleType == .night ? .dark : .light
        map.isPitchEnabled = true
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false
        map.isUserInteractionEnabled = false
        // Kein map.pointOfInterestFilter hier: Das alte Einzel-Attribut ersetzt die Kartenkonfiguration
        // (Höhenmodell) wieder durch die flache Standardkonfiguration – dann bleibt die Karte trotz Neigung 2D.
        if let here = AppModel.shared.location.lastLocation { follow(here, map: map, animated: false) }

        let controller = UIViewController()
        controller.view = map
        window.rootViewController = controller
        window.isHidden = false
        mapView = map
        connectedAt = Date()
        renderedLogged = false

        // Erst die Karte zeigen, dann den Rest: Beim Kaltstart (CarPlay startet Meeterz im Hintergrund) soll das
        // Dashboard nicht darauf warten, dass die Mapbox-Navigation hochfährt oder Freunde geladen sind.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mapView === map else { return }
            // Laufende Route
            navigationProvider.mapboxNavigation.tripSession().navigationRoutes
                .receive(on: DispatchQueue.main)
                .sink { [weak self] routes in self?.drawRoute(routes?.mainRoute.route.shape?.coordinates) }
                .store(in: &self.subscriptions)

            // Freunde alle 3 s abgleichen
            self.timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFriends(); self?.syncDayNight() }
            }
            self.refreshFriends()
        }

        Task { @MainActor [weak self, weak map, weak window] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let map else { return }
            let elevation = (map.preferredConfiguration as? MKHybridMapConfiguration)?.elevationStyle
                ?? (map.preferredConfiguration as? MKStandardMapConfiguration)?.elevationStyle
            Diag.log("\(self.name) nach 5 s (MapKit): \(Int(map.bounds.width))x\(Int(map.bounds.height)), im Fenster=\(map.window != nil), Fenster versteckt=\(window?.isHidden ?? true), Standort=\(map.userLocation.location != nil), Neigung \(Int(map.camera.pitch))°, Höhenmodell \(elevation == .realistic ? "realistisch" : "flach")")
        }
    }

    /// Kartenstil sofort übernehmen (Einstellung „Karte in CarPlay“ bzw. 2D/3D)
    func applyMapType() {
        // Kartenart gewechselt (Flyover ↔ Satellit/Klassisch): Karte neu aufbauen, damit sie wieder der großen gleicht
        if let window, (mapbox != nil) != Self.usesMapbox {
            let controller = dashboardController
            connect(window: window, zoom: zoomLevel)
            dashboardController = controller
            updateShortcuts()
            return
        }
        if mapbox != nil { applyMapboxStyle(); configureMapboxCamera(); return }
        guard let map = mapView else { return }
        Self.applyStyle(to: map)
        if let here = map.userLocation.location ?? AppModel.shared.location.lastLocation { follow(here, map: map, animated: true) }
    }

    /// Kartenart mit Höhenmodell: Mit dem bloßen `mapType` zeichnet MapKit flach (elevationStyle .flat),
    /// eine geneigte Kamera wirkt dann wie 2D. In 3D darum Gelände und Gebäude realistisch.
    private static func applyStyle(to map: MKMapView) {
        if CarPlayFlyoverMirror.isEnabled {
            map.mapType = .hybridFlyover
            return
        }
        let satellite = UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true
        let elevation: MKMapConfiguration.ElevationStyle = CarPlayController.threeDEnabled ? .realistic : .flat
        if satellite {
            let hybrid = MKHybridMapConfiguration(elevationStyle: elevation)
            hybrid.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation, .parking, .evCharger])
            map.preferredConfiguration = hybrid
        } else {
            let standard = MKStandardMapConfiguration(elevationStyle: elevation)
            standard.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation, .parking, .evCharger])
            map.preferredConfiguration = standard
        }
    }

    /// Neigung wie in der großen CarPlay-Karte: 3D geneigt, 2D von oben
    private static var pitch: CGFloat { CarPlayController.threeDEnabled ? CGFloat(CarPlayController.tilt3D) : 0 }

    /// Zuletzt gesetzte Knöpfe (nur bei Änderung neu setzen, sonst flackert die Kachel)
    private var shortcutKey = ""

    /// Schnellwahl im Dashboard: die zwei nächsten Freunde mit Profilbild – ein Tippen navigiert zu ihnen.
    /// Ist niemand sichtbar: Zuhause und Arbeit. (Apple erlaubt Apps hier höchstens zwei Knöpfe.)
    ///
    /// Ohne Knöpfe zeigte CarPlay im Dashboard vor einer Route nur Platzhalter.
    func updateShortcuts() {
        guard let controller = dashboardController else { return }
        let app = AppModel.shared
        let me = app.location.lastLocation?.coordinate
        let friends = app.friendsOnMap
            .sorted { a, b in
                guard let me else { return false }
                return a.position.coordinate.distance(to: me) < b.position.coordinate.distance(to: me)
            }
            .prefix(2)

        struct Shortcut { let key: String; let title: String; let subtitle: String; let image: UIImage; let place: Place }
        var shortcuts: [Shortcut] = friends.map { item in
            let f = item.friend
            let first = f.displayName.split(separator: " ").first.map(String.init) ?? f.displayName
            let faded = item.position.age > 5 * 60
            let image = AvatarRenderer.image(initials: f.initials, color: FriendPalette.uiColor(for: f.friendId),
                                             faded: faded, photo: app.avatars.image(for: f.friendId))
            // Ohne Entfernung: die wechselte beim Fahren ständig und lenkte im Augenwinkel ab. Der Knopf ändert sich
            // nur noch, wenn ein anderer Freund der nächste ist; navigiert wird zur aktuellen Position (beim Antippen).
            return Shortcut(key: "\(f.friendId)-\(faded)", title: first, subtitle: "", image: image,
                            place: Place(id: "friend-\(f.friendId)", name: f.displayName, address: nil,
                                         coordinate: item.position.coordinate))
        }
        if shortcuts.isEmpty {
            let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            let favs = [app.favorites.home, app.favorites.work].compactMap { $0 } + app.favorites.others
            shortcuts = favs.prefix(2).map { fav in
                Shortcut(key: fav.id.uuidString, title: fav.label, subtitle: fav.address ?? "",
                         image: UIImage(systemName: fav.symbol, withConfiguration: config) ?? UIImage(), place: fav.place)
            }
        }

        let key = shortcuts.map(\.key).joined(separator: "|")
        guard key != shortcutKey else { return }
        if shortcutKey.isEmpty || key.isEmpty {
            // Ohne Knöpfe zeigt CarPlay im Dashboard nur das App-Symbol – festhalten, wann welche da sind
            Diag.log("\(name): \(shortcuts.count) Schnellwahl-Knöpfe (angemeldet: \(app.profile != nil))")
        }
        shortcutKey = key
        controller.shortcutButtons = shortcuts.map { s in
            let place = s.place
            return CPDashboardButton(titleVariants: [s.title], subtitleVariants: s.subtitle.isEmpty ? [] : [s.subtitle], image: s.image) { _ in
                Task { @MainActor in
                    // Freund: Ziel ist seine Position jetzt, nicht die beim letzten Setzen des Knopfs
                    var target = place
                    if place.id.hasPrefix("friend-"),
                       let item = AppModel.shared.friendsOnMap.first(where: { "friend-\($0.friend.friendId)" == place.id }) {
                        target = Place(id: place.id, name: place.name, address: nil, coordinate: item.position.coordinate)
                    }
                    CarPlayController.shared.openFromDashboard(target, scene: CarPlayDashboard.shared.scene)
                }
            }
        }
    }

    func zoom(by delta: Double) {
        if mapbox != nil {
            ownZoom = min(max((ownZoom ?? zoomLevel) + delta, 10), 19)
            configureMapboxCamera()
            return
        }
        distance = min(max(distance * pow(2, -delta), 150), 60_000)
        if let map = mapView, let here = map.userLocation.location { follow(here, map: map, animated: true) }
    }

    func disconnect() {
        mapboxOverlay?.stop()
        mapboxOverlay = nil
        mapboxTokens.removeAll()
        mapbox?.removeFromSuperview()
        mapbox = nil
        container = nil
        dashboardController = nil
        shortcutKey = ""
        subscriptions.removeAll()
        timer?.invalidate()
        timer = nil
        pins = [:]
        routeOverlays = []
        mapView?.delegate = nil
        mapView?.removeFromSuperview()
        mapView = nil
    }

    // MARK: Kamera: folgt dem Standort, in Fahrtrichtung, leicht geneigt

    private func follow(_ location: CLLocation, map: MKMapView, animated: Bool) {
        // Dashboard: so nah wie die große Karte (derselbe Zoom, umgerechnet wie die Flyover-Ebene dort).
        // Vorher fester Abstand von ~1 km – MapKit begrenzte dabei die Neigung auf 34°, und das Bild sah anders aus.
        if ownZoom == nil, map.bounds.height > 1 {
            distance = CarPlayFlyoverMirror.distance(zoom: min(CarPlayController.shared.displayedZoom, Self.maxZoom),
                                                     latitude: location.coordinate.latitude, height: Double(map.bounds.height))
        }
        let heading = location.course >= 0 ? location.course : map.camera.heading
        let camera = MKMapCamera(lookingAtCenter: location.coordinate, fromDistance: distance, pitch: Self.pitch, heading: heading)
        map.setCamera(camera, animated: animated)
        // MapKit begrenzt die Neigung je nach Abstand (am 27.10.: 34° statt 60° bei ~1 km) – protokollieren, um die
        // Grenze zu kennen, statt zu raten
        if Self.pitch > 0, Date().timeIntervalSince(lastPitchLog) > 60 {
            lastPitchLog = Date()
            let actual = map.camera.pitch
            if abs(actual - Self.pitch) > 3 {
                Diag.log("\(name): Neigung \(Int(actual))° statt \(Int(Self.pitch))° bei \(Int(distance)) m Abstand (Höhe \(Int(map.camera.altitude)) m)")
            }
        }
    }
    private var lastPitchLog = Date.distantPast

    // MARK: Mapbox (Satellit/Klassisch) – wie die große CarPlay-Karte

    private func connectMapbox(window: UIWindow) {
        let core = navigationProvider.mapboxNavigation
        let nav = NavigationMapView(
            location: core.navigation().locationMatching.map(\.enhancedLocation).eraseToAnyPublisher(),
            routeProgress: core.navigation().routeProgress.map { $0?.routeProgress }.eraseToAnyPublisher(),
            routeRefreshing: core.navigation().routeRefreshing.eraseToAnyPublisher(),
            navigationCameraType: .carPlay
        )
        // Ursache für das frühere „Dashboard zeigt nur das App-Symbol“: Mapbox zeichnet nur in einer aktiven Szene,
        // die Dashboard-Szene meldet sich beim Verbinden aber als „nicht verbunden“. Darum in jedem Szenenzustand
        // zeichnen lassen und beim Aktivwerden der Szene neu einhängen (dann erkennt Mapbox die Szene).
        nav.mapView.displayState = [.foregroundActive, .foregroundInactive, .background]
        nav.puckType = .puck2D(.navigationCarPlayDefault)
        nav.mapView.ornaments.options.compass.visibility = .hidden
        nav.mapView.ornaments.options.scaleBar.visibility = .hidden
        nav.isUserInteractionEnabled = false
        nav.translatesAutoresizingMaskIntoConstraints = true
        nav.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let controller = DashboardContainer()
        controller.loadViewIfNeeded()
        nav.frame = controller.view.bounds
        controller.view.addSubview(nav)
        window.rootViewController = controller
        window.isHidden = false
        container = controller
        mapbox = nav
        mapboxRendered = false
        appliedStyleType = nil

        nav.mapView.mapboxMap.onMapIdle.observeNext { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.mapboxRendered else { return }
                self.mapboxRendered = true
                Diag.log("\(self.name) (Mapbox): Karte gezeichnet nach \(String(format: "%.1f", Date().timeIntervalSince(self.connectedAt))) s")
            }
        }.store(in: &mapboxTokens)
        applyMapboxStyle()

        let overlay = FriendOverlay(mapView: nav.mapView) { true }
        overlay.start()
        mapboxOverlay = overlay

        // Laufende Route wie auf der großen Karte; die Kamera rahmt dann wie dort
        core.tripSession().navigationRoutes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] routes in
                MainActor.assumeIsolated {
                    guard let self, let map = self.mapbox else { return }
                    if let routes { map.show(routes, routeAnnotationKinds: []) } else { map.removeRoutes() }
                    self.configureMapboxCamera()
                }
            }
            .store(in: &subscriptions)
        configureMapboxCamera()

        // Schnellwahl (Freunde/Zuhause) aktuell halten
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateShortcuts(); self?.syncDayNight() }
        }

        Task { @MainActor [weak self, weak nav] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let nav else { return }
            let cam = nav.mapView.mapboxMap.cameraState
            Diag.log("\(self.name) nach 5 s (Mapbox): \(Int(nav.bounds.width))x\(Int(nav.bounds.height)), im Fenster=\(nav.window != nil), gezeichnet=\(self.mapboxRendered), Neigung \(Int(cam.pitch))°, Zoom \(String(format: "%.1f", cam.zoom))")
        }
    }

    /// Die Dashboard-Szene wurde aktiv: Karte neu einhängen, damit Mapbox die Szene erkennt und zeichnet
    func sceneDidActivate() {
        guard let nav = mapbox, let host = container?.view else { return }
        nav.removeFromSuperview()
        nav.frame = host.bounds
        host.addSubview(nav)
    }

    /// Derselbe Kartenstil wie die große Karte: dieselben Mapbox-Stile (Navigationskarte bzw. Satellit) und Tag/Nacht
    /// wie dort. Vorher nahm das Dashboard Mapbox' allgemeinen „Standard“-Stil (anderes Aussehen, lädt deutlich länger)
    /// und Tag/Nacht vom eigenen Fenster – das meldet im Dashboard aber immer „dunkel“.
    private func applyMapboxStyle() {
        guard let nav = mapbox else { return }
        let satellite = UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true
        let type = CarPlayController.shared.mapStyleType ?? .day
        guard let style = NavigationStyles.carPlay().first(where: { $0.styleType == type }) else { return }
        appliedStyleType = type
        style.applyMapStyle(to: nav)
        Satellite3DBuildings.install(on: nav.mapView, satellite: satellite)
    }
    private var appliedStyleType: StyleType?

    /// Tag/Nacht der großen Karte gewechselt: nachziehen
    private func syncDayNight() {
        let type = CarPlayController.shared.mapStyleType ?? .day
        if mapbox != nil {
            if type != appliedStyleType { applyMapboxStyle() }
        } else if let map = mapView {
            let wanted: UIUserInterfaceStyle = type == .night ? .dark : .light
            if map.overrideUserInterfaceStyle != wanted { map.overrideUserInterfaceStyle = wanted }
        }
    }

    /// Neigung und Zoom wie die große Karte (3D-Einstellung, Zoom außerhalb der Fahrt bzw. Navigationszoom)
    private func configureMapboxCamera() {
        guard let nav = mapbox else { return }
        let navigating = AppModel.shared.navigation.isNavigating
        CarPlayController.shared.configureCamera(nav, navigating: navigating)
        guard let source = nav.navigationCamera.viewportDataSource as? CarPlayViewportDataSource else { return }
        var current = source.currentNavigationCameraOptions
        if let ownZoom {
            current.followingCamera.zoom = ownZoom
        } else if !navigating {
            // Nie näher als die Navigation selbst (17,5): Auf der großen Karte ganz hineingezoomt (18) flackerten im
            // kleinen Dashboard die 3D-Gebäude – so nah und 53° geneigt ragen sie vor der Kamera aus dem Bild (28.10.).
            current.followingCamera.zoom = min(CarPlayController.shared.browseZoom, Self.maxZoom)
        }
        source.currentNavigationCameraOptions = current
    }

    // MARK: Route und Freunde

    private func drawRoute(_ coords: [CLLocationCoordinate2D]?) {
        guard let map = mapView else { return }
        map.removeOverlays(routeOverlays)
        routeOverlays = []
        guard var c = coords, c.count > 1 else { return }
        let outline = StyledPolyline(coordinates: &c, count: c.count)
        outline.color = FriendPalette.routeCasing
        outline.width = 12
        let line = StyledPolyline(coordinates: &c, count: c.count)
        line.color = UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1)
        line.width = 8
        routeOverlays = [outline, line]
        map.addOverlays(routeOverlays, level: .aboveRoads)
    }

    private func refreshFriends() {
        updateShortcuts()
        guard let map = mapView else { return }   // Mapbox: FriendOverlay zeichnet die Freunde
        let items = AppModel.shared.friendsOnMap
        let wanted = Set(items.map(\.friend.friendId))
        for (id, pin) in pins where !wanted.contains(id) {
            map.removeAnnotation(pin)
            pins.removeValue(forKey: id)
        }
        for item in items {
            let id = item.friend.friendId
            if let pin = pins[id] {
                pin.coordinate = item.position.coordinate
                pin.kind = .friend(item)
                map.view(for: pin)?.image = pin.image()
            } else {
                let pin = MapPin(kind: .friend(item))
                pin.coordinate = item.position.coordinate
                pins[id] = pin
                map.addAnnotation(pin)
            }
        }
    }

    // MARK: MKMapViewDelegate

    /// Diagnose: Wann hat die Karte ihr erstes Bild fertig? Zeigt, ob Meeterz gezeichnet hat, während CarPlay
    /// noch den Platzhalter zeigt (dann liegt es an iOS) – oder ob die Karte selbst zu spät kam.
    nonisolated func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        MainActor.assumeIsolated {
            guard !renderedLogged else { return }
            renderedLogged = true
            let seconds = Date().timeIntervalSince(connectedAt)
            Diag.log("\(name): Karte gezeichnet nach \(String(format: "%.1f", seconds)) s (vollständig: \(fullyRendered), iPhone gesperrt: \(UIApplication.shared.isProtectedDataAvailable ? "nein" : "ja"))")
        }
    }

    nonisolated func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        MainActor.assumeIsolated {
            guard let location = userLocation.location else { return }
            follow(location, map: mapView, animated: true)
            if let view = mapView.view(for: userLocation) { Self.style(view, location: location, map: mapView) }
        }
    }

    /// Eigener Standort: Pfeil in Fahrtrichtung, sobald man fährt; im Stand ein Punkt
    private static let dotImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { _ in
        let rect = CGRect(x: 3, y: 3, width: 20, height: 20)
        UIColor.white.setFill(); UIBezierPath(ovalIn: rect).fill()
        UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1).setFill(); UIBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
    }

    private static func style(_ view: MKAnnotationView, location: CLLocation?, map: MKMapView) {
        let moving = (location?.speed ?? 0) > 1.5 && (location?.course ?? -1) >= 0
        view.image = moving ? CarPlayFlyoverMirror.arrowImage : dotImage
        view.bounds.size = view.image?.size ?? .zero
        let angle = moving ? CGFloat(((location?.course ?? 0) - map.camera.heading) * .pi / 180) : 0
        view.transform = CGAffineTransform(rotationAngle: angle)
    }

    nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? StyledPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = line.color
        renderer.lineWidth = line.width
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    /// Eigener Standortpunkt immer obenauf – sonst verdeckte ein Freund in der Nähe (Bild und Name) ihn
    nonisolated func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        MainActor.assumeIsolated {
            for view in views where view.annotation is MKUserLocation {
                view.zPriority = .max
                view.displayPriority = .required
                view.layer.zPosition = 1_000
            }
        }
    }

    nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        MainActor.assumeIsolated {
            if let me = annotation as? MKUserLocation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "me") ?? MKAnnotationView(annotation: me, reuseIdentifier: "me")
                view.annotation = me
                view.canShowCallout = false
                view.zPriority = .max
                view.displayPriority = .required
                Self.style(view, location: me.location, map: mapView)
                return view
            }
            guard let pin = annotation as? MapPin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin")
                ?? MKAnnotationView(annotation: pin, reuseIdentifier: "pin")
            view.annotation = pin
            view.canShowCallout = false
            view.image = pin.image()
            view.centerOffset = CGPoint(x: 0, y: -(view.image?.size.height ?? 0) / 2)
            view.displayPriority = .required
            view.zPriority = .defaultUnselected
            return view
        }
    }
}

/// Hält die Dashboard-Karte
final class DashboardContainer: UIViewController {}
