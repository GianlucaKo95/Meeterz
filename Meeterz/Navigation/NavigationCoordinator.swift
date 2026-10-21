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
/// Eigene Sprachausgabe: nimmt die in den Einstellungen gewählte oder beste installierte deutsche Stimme.
@MainActor
func meeterzCoreConfig(simulate: Bool, initialLocation: CLLocation? = nil) -> CoreConfig {
    CoreConfig(
        locationSource: simulate ? .simulation(initialLocation: initialLocation) : .live,
        locale: Locale(identifier: "de_DE"),
        ttsConfig: .custom(speechSynthesizer: MeeterzSpeechSynthesizer.shared)
    )
}

/// Routenplanung, Turn-by-Turn auf dem iPhone, Teilen der Route und Zwischenstopps.
@MainActor @Observable
final class NavigationCoordinator: NSObject {
    struct Preview: Identifiable {
        let id: UUID
        let destination: Place
        let routes: NavigationRoutes
        let mode: TravelMode
        init(id: UUID = UUID(), destination: Place, routes: NavigationRoutes, mode: TravelMode = .car) {
            self.id = id
            self.destination = destination
            self.routes = routes
            self.mode = mode
        }
        var eta: Date { Date().addingTimeInterval(routes.mainRoute.route.expectedTravelTime) }
        var distance: CLLocationDistance { routes.mainRoute.route.distance }
        /// Linien für die Vorschaukarte: zuerst die Hauptroute, danach Alternativen
        var lines: [[CLLocationCoordinate2D]] {
            options.compactMap { $0.shape?.coordinates }
        }
        /// Alle wählbaren Routen in fester Reihenfolge: Hauptroute, dann Alternativen
        var options: [Route] { [routes.mainRoute.route] + routes.alternativeRoutes.map(\.route) }
    }

    private(set) var isNavigating = false
    private(set) var isCalculating = false
    private(set) var destination: Place?
    private(set) var eta: Date?
    /// Restweg und -zeit der laufenden Navigation (für das CarPlay-Panel)
    private(set) var remaining: (distance: CLLocationDistance, duration: TimeInterval)?
    var preview: Preview?
    /// Gewählte Fortbewegungsart (wird gemerkt). Auf CarPlay gilt immer Auto.
    var travelMode: TravelMode = TravelMode.saved {
        didSet { TravelMode.saved = travelMode }
    }
    /// Art der laufenden Navigation (für das Teilen der Route)
    @ObservationIgnored private var activeMode: TravelMode = .car

    /// Mit CarPlay verbunden ist klar: man sitzt im Auto
    var effectiveMode: TravelMode { CarPlayController.shared.isConnected ? .car : travelMode }

    @ObservationIgnored private weak var phoneController: NavigationViewController?
    @ObservationIgnored private var overlay: FriendOverlay?
    @ObservationIgnored private var recenterTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()

    private var core: MapboxNavigation { navigationProvider.mapboxNavigation }

    /// Nur im Debug-Build: Fahrt simulieren statt echtem GPS (für Tests am Schreibtisch)
    static var simulate: Bool {
        get {
            #if DEBUG
            UserDefaults.standard.bool(forKey: "dev.simulate")
            #else
            false
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: "dev.simulate") }
    }

    // MARK: Route planen

    /// Berechnet Routen (mit Live-Traffic) vom aktuellen Standort über optionale Zwischenstopps zum Ziel.
    func calculate(to place: Place, via stops: [Place] = [], mode: TravelMode? = nil, silent: Bool = false) async -> NavigationRoutes? {
        let mode = mode ?? effectiveMode
        guard let origin = AppModel.shared.location.lastLocation?.coordinate else {
            AppModel.shared.show("Dein Standort ist noch nicht bekannt.")
            return nil
        }
        isCalculating = true
        defer { isCalculating = false }

        let waypoints = [Waypoint(coordinate: origin)]
            + stops.map { Waypoint(coordinate: $0.coordinate, name: $0.name) }
            + [Waypoint(coordinate: place.coordinate, name: place.name)]
        let options = NavigationRouteOptions(waypoints: waypoints, profileIdentifier: mode.profile,
                                             locale: Locale(identifier: "de_DE"), distanceUnit: .kilometer)

        do {
            return try await core.routingProvider().calculateRoutes(options: options).value
        } catch {
            if !silent { AppModel.shared.show(Self.friendly(error)) }
            return nil
        }
    }

    func planRoute(to place: Place) async {
        let mode = effectiveMode
        guard let routes = await calculate(to: place, mode: mode) else { return }
        preview = Preview(destination: place, routes: routes, mode: mode)
    }

    /// Vorschau mit anderer Fortbewegungsart neu berechnen (gleiche Vorschau-ID, das Fenster bleibt offen)
    func recalculate(_ old: Preview, mode: TravelMode) async -> Preview? {
        guard let routes = await calculate(to: old.destination, mode: mode) else { return nil }
        travelMode = mode
        return Preview(id: old.id, destination: old.destination, routes: routes, mode: mode)
    }

    /// Gibt es für diese Art überhaupt eine Route zum Ort? (Treffpunkt-Vorschlag)
    func canReach(_ place: Place, mode: TravelMode) async -> Bool {
        await calculate(to: place, mode: mode, silent: true) != nil
    }

    // MARK: Navigation starten / beenden

    func start(_ preview: Preview) {
        self.preview = nil
        activeMode = preview.mode
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

        // Erst das Vorschau-Sheet schließen lassen, dann die Navigation darüber legen.
        // Das Schließen dauert unterschiedlich lang; ein Present auf ein noch schließendes Sheet
        // schlägt stillschweigend fehl – deshalb warten und notfalls erneut versuchen.
        Task { @MainActor [weak self] in
            for attempt in 0..<30 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 450 : 300))
                guard let top = UIApplication.topViewController(),
                      !top.isBeingDismissed, !top.isBeingPresented,
                      top !== controller else { continue }
                top.present(controller, animated: true) {
                    Self.installMuteButton(on: controller)
                    self?.startAutoRecenter(controller)
                    if let mapView = controller.navigationMapView?.mapView {
                        Satellite3DBuildings.install(
                            on: mapView,
                            satellite: UserDefaults.standard.object(forKey: "map.satellite") as? Bool ?? true
                        )
                        let o = FriendOverlay(mapView: mapView) { true }
                        o.start()
                        self?.overlay = o
                    }
                    CarPlayController.shared.beginNavigationIfConnected()
                }
                try? await Task.sleep(for: .milliseconds(600))
                if controller.presentingViewController != nil { return }
            }
            // Gar nicht anzeigbar: Zustand zurücksetzen, damit die Karte nicht „navigiert“
            let top = UIApplication.topViewController()
            let info = top.map { "\(type(of: $0)), Sheet: \($0.presentationController is UISheetPresentationController), schließt: \($0.isBeingDismissed)" } ?? "kein Controller"
            self?.stop()
            AppModel.shared.show("Navigation konnte nicht gestartet werden (\(info)).")
        }
    }

    /// Wurde die Karte weggeschoben, springt die Kamera nach 10 s ohne Eingabe zurück zur Position.
    private func startAutoRecenter(_ controller: NavigationViewController) {
        recenterTask?.cancel()
        recenterTask = Task { @MainActor [weak controller] in
            var idleSeconds = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let camera = controller?.navigationMapView?.navigationCamera else { continue }
                if camera.currentCameraState == .idle {
                    idleSeconds += 1
                    if idleSeconds >= 10 {
                        camera.update(cameraState: .following)
                        idleSeconds = 0
                    }
                } else {
                    idleSeconds = 0
                }
            }
        }
    }

    /// Eigener, gut sichtbarer Stumm-Knopf anstelle des kleinen Mapbox-Knopfs
    private static func installMuteButton(on controller: NavigationViewController) {
        guard var buttons = controller.floatingButtons, buttons.count >= 2 else { return }
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "speaker.wave.2.fill"), for: .normal)
        button.setImage(UIImage(systemName: "speaker.slash.fill"), for: .selected)
        button.tintColor = .label
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 25
        button.layer.shadowOpacity = 0.25
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.isSelected = MeeterzSpeechSynthesizer.shared.muted
        button.accessibilityLabel = "Sprachansagen"
        button.accessibilityValue = button.isSelected ? "aus" : "an"
        button.widthAnchor.constraint(equalToConstant: 50).isActive = true
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        button.addAction(UIAction { [weak button] _ in
            guard let button else { return }
            let muted = !MeeterzSpeechSynthesizer.shared.muted
            MeeterzSpeechSynthesizer.shared.muted = muted
            button.isSelected = muted
            button.accessibilityValue = muted ? "aus" : "an"
        }, for: .touchUpInside)
        buttons[1] = button
        controller.floatingButtons = buttons
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
        guard let routes = await calculate(to: destination, via: [stop], mode: activeMode) else { return }
        core.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)
        AppModel.shared.show("\(stop.name) als Zwischenstopp hinzugefügt.", isError: false)
    }

    func stop() {
        guard isNavigating || phoneController != nil else { return }
        subscriptions.removeAll()
        overlay?.stop()
        overlay = nil
        recenterTask?.cancel()
        recenterTask = nil
        navigationProvider.tripSession().setToIdle()
        phoneController?.dismiss(animated: true)
        phoneController = nil
        isNavigating = false
        AppModel.shared.location.setNavigating(false)
        destination = nil
        eta = nil
        remaining = nil
        Task { await AppModel.shared.routes.clearMine() }
    }

    // MARK: Route teilen

    private func beginTracking() {
        isNavigating = true
        AppModel.shared.location.setNavigating(true)
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
        // Inkognito oder „Routen verbergen“: Route gar nicht erst hochladen
        if let me = AppModel.shared.profile, me.isIncognito || me.routesHidden { return }
        await AppModel.shared.routes.shareMine(
            destinationName: destination?.name,
            destination: dest,
            eta: arrival,
            points: points,
            mode: activeMode
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
