import UIKit
import CarPlay
import Combine
import CoreLocation
import MapKit
import MapboxNavigationCore

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
            CarPlayDashboard.shared.connect(window: window)
            CarPlayDashboard.shared.dashboardController = dashboardController
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
    func sceneDidBecomeActive(_ scene: UIScene) { MainActor.assumeIsolated { Diag.log("Dashboard-Szene: aktiv") } }
    func sceneWillResignActive(_ scene: UIScene) { MainActor.assumeIsolated { Diag.log("Dashboard-Szene: wird inaktiv") } }
    func sceneWillEnterForeground(_ scene: UIScene) { MainActor.assumeIsolated { Diag.log("Dashboard-Szene: Vordergrund") } }
    func sceneDidEnterBackground(_ scene: UIScene) { MainActor.assumeIsolated { Diag.log("Dashboard-Szene: Hintergrund") } }
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

/// Dashboard- und Kombiinstrument-Karte mit Apple MapKit.
///
/// Vorher lief hier eine Mapbox-Karte. Mapbox zeichnet nur, solange es die Szene als aktiv erkennt;
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
    private var distance: CLLocationDistance = 900
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var pins: [UUID: MapPin] = [:]
    private var routeOverlays: [MKOverlay] = []

    private init(name: String) {
        self.name = name
        super.init()
    }

    func connect(window: UIWindow, zoom: Double = 15.5) {
        disconnect()
        // Zoomstufe grob in Kameraabstand umrechnen (16 ≈ 700 m)
        distance = 700 * pow(2, 16 - zoom)

        let map = MKMapView(frame: window.bounds)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = self
        map.mapType = Self.mapType
        map.showsUserLocation = true
        map.showsCompass = false
        map.showsScale = false
        map.isUserInteractionEnabled = false
        map.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation, .parking, .evCharger])
        if let here = AppModel.shared.location.lastLocation { follow(here, map: map, animated: false) }

        let controller = UIViewController()
        controller.view = map
        window.rootViewController = controller
        mapView = map

        // Laufende Route
        navigationProvider.mapboxNavigation.tripSession().navigationRoutes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] routes in self?.drawRoute(routes?.mainRoute.route.shape?.coordinates) }
            .store(in: &subscriptions)

        // Freunde alle 3 s abgleichen
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFriends() }
        }
        refreshFriends()

        Task { @MainActor [weak self, weak map, weak window] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let map else { return }
            Diag.log("\(self.name) nach 5 s (MapKit): \(Int(map.bounds.width))x\(Int(map.bounds.height)), im Fenster=\(map.window != nil), Fenster versteckt=\(window?.isHidden ?? true), Standort=\(map.userLocation.location != nil)")
        }
    }

    private static var mapType: MKMapType {
        CarPlayFlyoverMirror.isEnabled ? .hybridFlyover
            : (UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true) ? .hybrid : .standard
    }

    /// Kartenstil sofort übernehmen (Einstellung „Karte in CarPlay“)
    func applyMapType() {
        mapView?.mapType = Self.mapType
    }

    /// Bis zu zwei Schnellwahl-Knöpfe wie bei Apple Karten: Zuhause, Arbeit bzw. die ersten Favoriten.
    ///
    /// Ohne Knöpfe zeigte CarPlay im Dashboard vor einer Route nur Platzhalter (Kachel oben rechts und
    /// teils die Karte). Apple sieht die Knöpfe genau für die Zeit ohne Navigation vor.
    func updateShortcuts() {
        guard let controller = dashboardController else { return }
        let f = AppModel.shared.favorites
        let favorites = Array(([f.home, f.work].compactMap { $0 } + f.others).prefix(2))
        let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        var buttons: [CPDashboardButton] = favorites.map { fav in
            let place = fav.place
            return CPDashboardButton(
                titleVariants: [fav.label],
                subtitleVariants: [fav.address ?? ""],
                image: UIImage(systemName: fav.symbol, withConfiguration: config) ?? UIImage()
            ) { _ in
                Task { @MainActor in CarPlayController.shared.startGuidance(to: place) }
            }
        }
        if buttons.isEmpty {
            // Ohne Favoriten: Freunde in der Nähe (nächster Freund als Ziel)
            if let friend = AppModel.shared.friendsOnMap.first {
                let place = Place(id: "friend-\(friend.friend.friendId)", name: friend.friend.displayName,
                                  address: nil, coordinate: friend.position.coordinate)
                buttons = [CPDashboardButton(titleVariants: [friend.friend.displayName], subtitleVariants: ["Zum Freund"],
                                             image: UIImage(systemName: "person.crop.circle.fill", withConfiguration: config) ?? UIImage()) { _ in
                    Task { @MainActor in CarPlayController.shared.startGuidance(to: place) }
                }]
            }
        }
        controller.shortcutButtons = buttons
        Diag.log("Dashboard: \(buttons.count) Schnellwahl-Knöpfe")
    }

    func zoom(by delta: Double) {
        distance = min(max(distance * pow(2, -delta), 150), 60_000)
        if let map = mapView, let here = map.userLocation.location { follow(here, map: map, animated: true) }
    }

    func disconnect() {
        dashboardController = nil
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
        let heading = location.course >= 0 ? location.course : map.camera.heading
        let camera = MKMapCamera(lookingAtCenter: location.coordinate, fromDistance: distance, pitch: 55, heading: heading)
        map.setCamera(camera, animated: animated)
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
        guard let map = mapView else { return }
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

    nonisolated func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        MainActor.assumeIsolated {
            guard let location = userLocation.location else { return }
            follow(location, map: mapView, animated: true)
        }
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

    nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        MainActor.assumeIsolated {
            guard let pin = annotation as? MapPin else { return nil }   // eigener Standort: Standard-Punkt
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin")
                ?? MKAnnotationView(annotation: pin, reuseIdentifier: "pin")
            view.annotation = pin
            view.canShowCallout = false
            view.image = pin.image()
            view.centerOffset = CGPoint(x: 0, y: -(view.image?.size.height ?? 0) / 2)
            view.displayPriority = .required
            return view
        }
    }
}
