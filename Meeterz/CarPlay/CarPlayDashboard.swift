import UIKit
import CarPlay
import Combine
import CoreLocation
import MapboxMaps
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
            Diag.log("Dashboard verbunden: Fenster \(Int(window.bounds.width))x\(Int(window.bounds.height)), versteckt=\(window.isHidden), Szene=\(templateApplicationDashboardScene.activationState.rawValue)")
            CarPlayDashboard.shared.connect(window: window, name: "Dashboard")
        }
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        MainActor.assumeIsolated { CarPlayDashboard.shared.disconnect() }
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
        MainActor.assumeIsolated { CarPlayDashboard.cluster.connect(window: instrumentClusterWindow, zoom: 16.5, name: "Kombiinstrument") }
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

@MainActor
final class CarPlayDashboard {
    static let shared = CarPlayDashboard()
    /// Dieselbe Karte im Kombiinstrument
    static let cluster = CarPlayDashboard()

    private var zoomLevel: Double = 15.5

    private var mapView: MapView?
    private var overlay: FriendOverlay?
    private var routeManager: PolylineAnnotationManager?
    private var subscriptions = Set<AnyCancellable>()
    private var cancelables = Set<AnyCancelable>()

    func connect(window: UIWindow, zoom: Double = 15.5, name: String) {
        disconnect()
        zoomLevel = zoom
        let satellite = UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true
        let options = MapInitOptions(
            cameraOptions: CameraOptions(zoom: zoomLevel, pitch: 55),
            styleURI: satellite ? .standardSatellite : .standard
        )
        let map = MapView(frame: window.bounds, mapInitOptions: options)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.ornaments.options.scaleBar.visibility = .hidden
        map.ornaments.options.compass.visibility = .hidden
        map.location.options.puckType = .puck2D(.makeDefault(showBearing: true))
        map.location.options.puckBearing = .course

        let controller = UIViewController()
        controller.view = map
        window.rootViewController = controller
        mapView = map

        // Diagnose: Lädt die Karte? (Dashboard zeigte nur das App-Symbol)
        map.mapboxMap.onMapLoaded.observeNext { _ in Diag.log("\(name): Karte geladen") }.store(in: &cancelables)
        map.mapboxMap.onMapLoadingError.observe { e in Diag.log("\(name): Kartenfehler \(e.type) \(e.message)") }.store(in: &cancelables)
        Task { @MainActor [weak map, weak window] in
            try? await Task.sleep(for: .seconds(5))
            guard let map else { return }
            Diag.log("\(name) nach 5 s: Karte \(Int(map.bounds.width))x\(Int(map.bounds.height)), im Fenster=\(map.window != nil), Fenster versteckt=\(window?.isHidden ?? true), Standort=\(map.location.latestLocation != nil)")
        }

        // Kamera folgt dem Standort
        follow()

        Satellite3DBuildings.install(on: map, satellite: satellite)
        let friends = FriendOverlay(mapView: map) { true }
        friends.start()
        overlay = friends

        // Laufende Route einzeichnen
        let manager = map.annotations.makePolylineAnnotationManager(id: "meeterz-dashboard-route")
        routeManager = manager
        navigationProvider.mapboxNavigation.tripSession().navigationRoutes
            .receive(on: DispatchQueue.main)
            .sink { routes in
                guard let coords = routes?.mainRoute.route.shape?.coordinates else {
                    manager.annotations = []
                    return
                }
                var line = PolylineAnnotation(id: "route", lineCoordinates: coords)
                line.lineColor = StyleColor(UIColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1))
                line.lineWidth = 8
                manager.annotations = [line]
            }
            .store(in: &subscriptions)
    }

    private func follow() {
        guard let map = mapView else { return }
        let state = map.viewport.makeFollowPuckViewportState(
            options: FollowPuckViewportStateOptions(zoom: zoomLevel, bearing: .course, pitch: 55))
        map.viewport.transition(to: state)
    }

    func zoom(by delta: Double) {
        zoomLevel = min(max(zoomLevel + delta, 10), 19)
        follow()
    }

    func disconnect() {
        cancelables.removeAll()
        subscriptions.removeAll()
        overlay?.stop()
        overlay = nil
        routeManager?.annotations = []
        routeManager = nil
        mapView?.removeFromSuperview()
        mapView = nil
    }
}
