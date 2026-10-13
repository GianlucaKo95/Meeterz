import Foundation
import UIKit
import Combine
import CoreLocation
import Observation
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit

/// Ein Navigationskern für iPhone und CarPlay (Vorgabe von Mapbox).
@MainActor
let navigationProvider = MapboxNavigationProvider(coreConfig: meeterzCoreConfig(simulate: false))

/// Sprachansagen nur mit Apple-Stimmen (offline, ohne Mapbox Speech API).
/// Die Stimme folgt der Systemeinstellung unter Bedienungshilfen → Gesprochene Inhalte.
func meeterzCoreConfig(simulate: Bool, initialLocation: CLLocation? = nil) -> CoreConfig {
    CoreConfig(
        locationSource: simulate ? .simulation(initialLocation: initialLocation) : .live,
        ttsConfig: .localOnly
    )
}

/// Routenplanung, Turn-by-Turn auf dem iPhone, Teilen der Route und Zwischenstopps.
@MainActor @Observable
final class NavigationCoordinator: NSObject {
    struct Preview: Identifiable {
        let id = UUID()
        let destination: Place
        let routes: NavigationRoutes
        var eta: Date { Date().addingTimeInterval(routes.mainRoute.route.expectedTravelTime) }
        var distance: CLLocationDistance { routes.mainRoute.route.distance }
    }

    private(set) var isNavigating = false
    private(set) var isCalculating = false
    private(set) var destination: Place?
    private(set) var eta: Date?
    /// Restweg und -zeit der laufenden Navigation (für das CarPlay-Panel)
    private(set) var remaining: (distance: CLLocationDistance, duration: TimeInterval)?
    var preview: Preview?

    @ObservationIgnored private weak var phoneController: NavigationViewController?
    @ObservationIgnored private var overlay: FriendOverlay?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()

    private var core: MapboxNavigation { navigationProvider.mapboxNavigation }

    /// Nur im Debug-Build: Fahrt simulieren statt echtem GPS (für Tests am Schreibtisch)
    static var simulate: Bool {
        get { UserDefaults.standard.bool(forKey: "dev.simulate") }
        set { UserDefaults.standard.set(newValue, forKey: "dev.simulate") }
    }

    // MARK: Route planen

    /// Berechnet Routen (mit Live-Traffic) vom aktuellen Standort über optionale Zwischenstopps zum Ziel.
    func calculate(to place: Place, via stops: [Place] = []) async -> NavigationRoutes? {
        guard let origin = AppModel.shared.location.lastLocation?.coordinate else {
            AppModel.shared.show("Dein Standort ist noch nicht bekannt.")
            return nil
        }
        isCalculating = true
        defer { isCalculating = false }

        let waypoints = [Waypoint(coordinate: origin)]
            + stops.map { Waypoint(coordinate: $0.coordinate, name: $0.name) }
            + [Waypoint(coordinate: place.coordinate, name: place.name)]
        let options = NavigationRouteOptions(waypoints: waypoints, locale: Locale(identifier: "de_DE"), distanceUnit: .kilometer)

        do {
            return try await core.routingProvider().calculateRoutes(options: options).value
        } catch {
            AppModel.shared.show(Self.friendly(error))
            return nil
        }
    }

    func planRoute(to place: Place) async {
        guard let routes = await calculate(to: place) else { return }
        preview = Preview(destination: place, routes: routes)
    }

    // MARK: Navigation starten / beenden

    func start(_ preview: Preview) {
        self.preview = nil
        destination = preview.destination
        remaining = (preview.distance, preview.routes.mainRoute.route.expectedTravelTime)

        navigationProvider.apply(coreConfig: meeterzCoreConfig(
            simulate: Self.simulate,
            initialLocation: AppModel.shared.location.lastLocation
        ))

        let options = NavigationOptions(
            mapboxNavigation: core,
            voiceController: navigationProvider.routeVoiceController,
            eventsManager: navigationProvider.eventsManager(),
            styles: NavigationStyles.phone(),
            predictiveCacheManager: navigationProvider.predictiveCacheManager
        )
        let controller = NavigationViewController(navigationRoutes: preview.routes, navigationOptions: options)
        controller.modalPresentationStyle = .fullScreen
        controller.routeLineTracksTraversal = true
        controller.usesNightStyleInDarkMode = true
        controller.delegate = self
        phoneController = controller

        beginTracking()

        // Erst das Vorschau-Sheet schließen lassen, dann die Navigation darüber legen
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            UIApplication.topViewController()?.present(controller, animated: true) {
                if let mapView = controller.navigationMapView?.mapView {
                    let o = FriendOverlay(mapView: mapView) { true }
                    o.start()
                    self?.overlay = o
                }
                CarPlayController.shared.beginNavigationIfConnected()
            }
        }
    }

    /// Navigation wurde auf CarPlay gestartet (ohne iPhone-Oberfläche)
    func didBeginOnCarPlay(destination place: Place?) {
        if let place { destination = place }
        beginTracking()
    }

    /// Zwischenstopp (z. B. Treffpunkt) in die laufende Navigation einfügen
    func addStop(_ stop: Place) async {
        guard isNavigating, let destination else {
            await planRoute(to: stop)
            return
        }
        guard let routes = await calculate(to: destination, via: [stop]) else { return }
        core.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)
        AppModel.shared.show("\(stop.name) als Zwischenstopp hinzugefügt.", isError: false)
    }

    func stop() {
        guard isNavigating || phoneController != nil else { return }
        subscriptions.removeAll()
        overlay?.stop()
        overlay = nil
        navigationProvider.tripSession().setToIdle()
        phoneController?.dismiss(animated: true)
        phoneController = nil
        isNavigating = false
        destination = nil
        eta = nil
        remaining = nil
        Task { await AppModel.shared.routes.clearMine() }
    }

    // MARK: Route teilen

    private func beginTracking() {
        isNavigating = true
        subscriptions.removeAll()

        // Fortschritt: höchstens jede Minute teilen (Verkehr ändert die Ankunftszeiten)
        core.navigation().routeProgress
            .compactMap { $0?.routeProgress }
            .throttle(for: .seconds(60), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] progress in
                Task { @MainActor in await self?.share(progress) }
            }
            .store(in: &subscriptions)

        // Neue Route (Umleitung, Zwischenstopp): sofort teilen
        core.tripSession().navigationRoutes
            .compactMap { $0 }
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let progress = navigationProvider.mapboxNavigation.navigation().currentRouteProgress?.routeProgress
                    else { return }
                    await self?.share(progress)
                }
            }
            .store(in: &subscriptions)

        Task { await applyArrivalSharing() }
    }

    private func share(_ progress: RouteProgress) async {
        let points = RouteSampler.sharePoints(
            route: progress.route,
            distanceTraveled: progress.distanceTraveled,
            durationRemaining: progress.durationRemaining
        )
        let arrival = Date().addingTimeInterval(progress.durationRemaining)
        eta = arrival
        remaining = (progress.distanceRemaining, progress.durationRemaining)
        let dest = destination?.coordinate
            ?? progress.route.shape?.coordinates.last
            ?? AppModel.shared.location.lastLocation?.coordinate
        guard let dest else { return }
        await AppModel.shared.routes.shareMine(
            destinationName: destination?.name,
            destination: dest,
            eta: arrival,
            points: points
        )
    }

    /// Modus „Bis Ankunft": Teilen endet 15 Minuten nach der geplanten Ankunft
    private func applyArrivalSharing() async {
        guard SharingMode.current == .untilArrival else { return }
        let remaining = core.navigation().currentRouteProgress?.routeProgress.durationRemaining
            ?? core.tripSession().currentNavigationRoutes?.mainRoute.route.expectedTravelTime
            ?? 3600
        await AppModel.shared.auth.setSharing(true, until: Date().addingTimeInterval(remaining + 15 * 60))
    }

    private static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("429") || text.contains("rate") || text.contains("402") {
            return "Das Navigationskontingent ist für diesen Monat aufgebraucht."
        }
        if text.contains("offline") || text.contains("internet") {
            return "Keine Internetverbindung – Route kann nicht berechnet werden."
        }
        return "Route konnte nicht berechnet werden."
    }
}

extension NavigationCoordinator: NavigationViewControllerDelegate {
    nonisolated func navigationViewControllerDidDismiss(
        _ navigationViewController: NavigationViewController,
        byCanceling canceled: Bool
    ) {
        Task { @MainActor in
            self.stop()
            CarPlayController.shared.endNavigationIfNeeded()
        }
    }
}

/// Wie lange der Standort geteilt wird
enum SharingMode: String, CaseIterable, Identifiable {
    case always, oneHour, untilArrival

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Immer"
        case .oneHour: "1 Std."
        case .untilArrival: "Bis Ankunft"
        }
    }

    static var current: SharingMode {
        get { SharingMode(rawValue: UserDefaults.standard.string(forKey: "sharing.mode") ?? "") ?? .always }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sharing.mode") }
    }
}

extension UIApplication {
    /// Oberster sichtbarer ViewController der iPhone-Szene (nicht CarPlay)
    static func topViewController() -> UIViewController? {
        let scenes = shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}
