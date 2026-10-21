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
        MainActor.assumeIsolated { CarPlayDashboard.shared.connect(window: window) }
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        MainActor.assumeIsolated { CarPlayDashboard.shared.disconnect() }
    }
}

@MainActor
final class CarPlayDashboard {
    static let shared = CarPlayDashboard()

    private var mapView: MapView?
    private var overlay: FriendOverlay?
    private var routeManager: PolylineAnnotationManager?
    private var subscriptions = Set<AnyCancellable>()

    func connect(window: UIWindow) {
        disconnect()
        let satellite = UserDefaults.standard.object(forKey: "carplay.satellite") as? Bool ?? true
        let options = MapInitOptions(
            cameraOptions: CameraOptions(zoom: 15.5, pitch: 55),
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

        // Kamera folgt dem Standort
        let follow = map.viewport.makeFollowPuckViewportState(
            options: FollowPuckViewportStateOptions(zoom: 15.5, bearing: .course, pitch: 55))
        map.viewport.transition(to: follow)

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

    func disconnect() {
        subscriptions.removeAll()
        overlay?.stop()
        overlay = nil
        routeManager?.annotations = []
        routeManager = nil
        mapView?.removeFromSuperview()
        mapView = nil
    }
}
