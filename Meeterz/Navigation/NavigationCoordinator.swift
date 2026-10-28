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
        // Schnellere Route: mit CarPlay erst fragen (Hinweis „x Min. sparen – wechseln?“), sonst wie bisher automatisch
        routingConfig: RoutingConfig(fasterRouteDetectionConfig: FasterRouteDetectionConfig(
            fasterRouteApproval: .manually({ context in
                await CarPlayController.shared.approveFasterRoute(context.1)
            })
        )),
        locationSource: simulate ? .simulation(initialLocation: initialLocation) : .live,
        locale: Locale.navigation,
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
    /// Startet immer mit Auto; in der Vorschau umstellbar. Wird nicht gespeichert – sonst blieb z. B. „Fahrrad“
    /// hängen, und die nächste lange Strecke scheiterte mit einem Fehler.
    var travelMode: TravelMode = .car
    /// Art der laufenden Navigation (für das Teilen der Route)
    @ObservationIgnored private var activeMode: TravelMode = .car

    /// Mit CarPlay verbunden ist klar: man sitzt im Auto
    var effectiveMode: TravelMode { CarPlayController.shared.isConnected ? .car : travelMode }

    @ObservationIgnored private weak var phoneController: NavigationViewController?
    @ObservationIgnored private var overlay: FriendOverlay?
    @ObservationIgnored private var recenterTask: Task<Void, Never>?
    @ObservationIgnored private var signTimer: Timer?
    @ObservationIgnored private var overviewToken: AnyCancellable?
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
            AppModel.shared.show(String(localized: "Dein Standort ist noch nicht bekannt."))
            return nil
        }
        isCalculating = true
        defer { isCalculating = false }

        let waypoints = [Waypoint(coordinate: origin)]
            + stops.map { Waypoint(coordinate: $0.coordinate, name: $0.name) }
            + [Waypoint(coordinate: place.coordinate, name: place.name)]
        let options = NavigationRouteOptions(waypoints: waypoints, profileIdentifier: mode.profile,
                                             locale: Locale.navigation, distanceUnit: .kilometer)
        RoutePreferences.apply(to: options)

        do {
            let routes = try await core.routingProvider().calculateRoutes(options: options).value
            // Auto: bis zu drei Routen – schnellste, kürzeste, ohne Autobahn
            guard mode == .car, stops.isEmpty else { return routes }
            return await RouteVariety.widen(routes, options: options, using: core.routingProvider())
        } catch where !options.roadClassesToAvoid.isEmpty {
            // Ohne Maut/Autobahn/Fähre nicht erreichbar (z. B. Insel nur per Fähre): dann normal, mit Hinweis
            let plain = NavigationRouteOptions(waypoints: waypoints, profileIdentifier: mode.profile,
                                               locale: Locale.navigation, distanceUnit: .kilometer)
            if let routes = try? await core.routingProvider().calculateRoutes(options: plain).value {
                if !silent { AppModel.shared.show(String(localized: "Nicht möglich \(RoutePreferences.summary ?? "") – Route ohne Einschränkung"), isError: false) }
                return routes
            }
            if !silent { AppModel.shared.show(Self.friendly(error)) }
            return nil
        } catch {
            if !silent {
                AppModel.shared.show(mode == .car ? Self.friendly(error)
                    : String(localized: "Keine Route \(mode.activity) gefunden – für lange Strecken auf „Auto“ umstellen."))
            }
            return nil
        }
    }

    /// Auto-Route zu einem Ort ohne Berechnen-Anzeige; mit `departing` Verkehrsprognose für diese Abfahrtszeit
    func driveRoute(to coordinate: CLLocationCoordinate2D, departing: Date? = nil) async -> Route? {
        guard let origin = AppModel.shared.location.lastLocation?.coordinate else { return nil }
        let options = NavigationRouteOptions(waypoints: [Waypoint(coordinate: origin), Waypoint(coordinate: coordinate)],
                                             profileIdentifier: .automobileAvoidingTraffic,
                                             locale: Locale.navigation, distanceUnit: .kilometer)
        options.departAt = departing
        RoutePreferences.apply(to: options)
        return try? await core.routingProvider().calculateRoutes(options: options).value.mainRoute.route
    }

    /// Fahrzeit mit dem Auto zu einem Ort, ohne die Berechnen-Anzeige der App (z. B. für die Zielliste auf CarPlay)
    func driveTime(to coordinate: CLLocationCoordinate2D) async -> TimeInterval? {
        guard let origin = AppModel.shared.location.lastLocation?.coordinate else { return nil }
        let options = NavigationRouteOptions(waypoints: [Waypoint(coordinate: origin), Waypoint(coordinate: coordinate)],
                                             profileIdentifier: .automobileAvoidingTraffic,
                                             locale: Locale.navigation, distanceUnit: .kilometer)
        RoutePreferences.apply(to: options)
        let routes = try? await core.routingProvider().calculateRoutes(options: options).value
        return routes?.mainRoute.route.expectedTravelTime
    }

    func planRoute(to place: Place, mode requested: TravelMode? = nil) async {
        let mode = requested ?? .car
        travelMode = mode
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
        AppModel.shared.recents.record(preview.destination)
        remaining = (preview.distance, preview.routes.mainRoute.route.expectedTravelTime)

        navigationProvider.apply(coreConfig: meeterzCoreConfig(
            simulate: Self.simulate,
            initialLocation: AppModel.shared.location.lastLocation
        ))

        presentPhone(routes: preview.routes, fromCarPlay: false)
    }

    /// Turn-by-Turn auf dem iPhone anzeigen. Beim Start auf CarPlay mit den dort laufenden Routen –
    /// so sieht man die Fahrt auch auf dem Handy (wie bei Apple Karten).
    private func presentPhone(routes: NavigationRoutes, fromCarPlay: Bool) {
        let options = NavigationOptions(
            mapboxNavigation: core,
            voiceController: navigationProvider.routeVoiceController,
            eventsManager: navigationProvider.eventsManager(),
            styles: NavigationStyles.phone(),
            predictiveCacheManager: navigationProvider.predictiveCacheManager
        )
        let controller = NavigationViewController(navigationRoutes: routes, navigationOptions: options)
        controller.modalPresentationStyle = .fullScreen
        controller.routeLineTracksTraversal = true
        controller.usesNightStyleInDarkMode = true
        controller.delegate = self
        phoneController = controller

        // Vorfahrt achten / Stopp unter dem Tempolimit auf dem iPhone (CarPlay: eigener Takt in CarPlayExtras)
        signTimer?.invalidate()
        signTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let view = self?.phoneController?.navigationView.speedLimitView else { return }
                RightOfWaySigns.shared.update(below: [view])
            }
        }

        if !fromCarPlay { beginTracking() }

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
                    self?.installOverviewButton(on: controller)
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
                    if !fromCarPlay { CarPlayController.shared.beginNavigationIfConnected() }
                }
                try? await Task.sleep(for: .milliseconds(600))
                if controller.presentingViewController != nil { return }
            }
            let top = UIApplication.topViewController()
            let info = top.map { "\(type(of: $0)), Sheet: \($0.presentationController is UISheetPresentationController), schließt: \($0.isBeingDismissed)" } ?? "kein Controller"
            if fromCarPlay {
                // CarPlay navigiert weiter – nur das iPhone zeigt die Fahrt nicht
                if self?.phoneController === controller { self?.phoneController = nil }
                Diag.log("iPhone-Navigation zur CarPlay-Fahrt nicht anzeigbar (\(info))")
                return
            }
            // Gar nicht anzeigbar: Zustand zurücksetzen, damit die Karte nicht „navigiert“
            self?.stop()
            AppModel.shared.show(String(localized: "Navigation konnte nicht gestartet werden (\(info))."))
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

    /// Übersichts-Knopf, der in der Übersicht (oder nach Verschieben) zum Ortungspfeil wird – ein Tipp führt zurück
    /// zur Abbiegeführung. Mapbox blendete stattdessen unten links einen eigenen „Fortsetzen“-Knopf ein; der entfällt.
    private func installOverviewButton(on controller: NavigationViewController) {
        guard var buttons = controller.floatingButtons, !buttons.isEmpty,
              let camera = controller.navigationMapView?.navigationCamera else { return }
        let button = UIButton(type: .system)
        button.tintColor = .label
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 25
        button.layer.shadowOpacity = 0.25
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.widthAnchor.constraint(equalToConstant: 50).isActive = true
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        func refresh(_ state: NavigationCameraState) {
            let following = state == .following
            button.setImage(UIImage(systemName: following ? "point.topleft.down.to.point.bottomright.curvepath"
                                                          : "location.north.line.fill"), for: .normal)
            button.accessibilityLabel = following ? String(localized: "Routenübersicht") : String(localized: "Zurück zur Navigation")
            // Mapbox' eigenen „Fortsetzen“-Knopf unsichtbar halten (Mapbox schaltet nur isHidden um)
            Self.hideResumeButton(in: controller.view)
        }
        refresh(camera.currentCameraState)
        button.addAction(UIAction { _ in
            camera.update(cameraState: camera.currentCameraState == .following ? .overview : .following)
        }, for: .touchUpInside)
        overviewToken = camera.cameraStates
            .receive(on: DispatchQueue.main)
            .sink { state in MainActor.assumeIsolated { refresh(state) } }
        buttons[0] = button
        controller.floatingButtons = buttons
    }

    private static func hideResumeButton(in view: UIView?) {
        guard let view else { return }
        for sub in view.subviews {
            if sub is ResumeButton { sub.alpha = 0; sub.isUserInteractionEnabled = false } else { hideResumeButton(in: sub) }
        }
    }

    /// Eigener, gut sichtbarer Stumm-Knopf anstelle des kleinen Mapbox-Knopfs
    private static func installMuteButton(on controller: NavigationViewController) {
        guard var buttons = controller.floatingButtons, buttons.count >= 2 else { return }
        let button = UIButton(type: .system)
        func refresh() {
            let mode = MeeterzSpeechSynthesizer.shared.mode
            button.setImage(UIImage(systemName: mode.symbol), for: .normal)
            button.accessibilityValue = mode.title
        }
        refresh()
        button.tintColor = .label
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 25
        button.layer.shadowOpacity = 0.25
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.accessibilityLabel = String(localized: "Sprachansagen")
        button.widthAnchor.constraint(equalToConstant: 50).isActive = true
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        // Wie Apple Karten: Tippen schaltet durch Alle Ansagen → Nur Warnungen → Aus
        button.addAction(UIAction { _ in
            MeeterzSpeechSynthesizer.shared.mode = MeeterzSpeechSynthesizer.shared.mode.next
            refresh()
            CarPlayController.shared.refreshVoiceButton()
        }, for: .touchUpInside)
        buttons[1] = button
        controller.floatingButtons = buttons
    }

    /// Navigation wurde auf CarPlay gestartet (ohne iPhone-Oberfläche)
    func didBeginOnCarPlay(destination place: Place?) {
        if let place { destination = place; AppModel.shared.recents.record(place) }
        activeMode = .car
        beginTracking()
        // Auch auf dem iPhone die laufende Fahrt zeigen (offene Sheets wie die Vorschau vorher schließen)
        guard phoneController == nil else { return }
        preview = nil
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let self, self.isNavigating, self.phoneController == nil else { return }
                if let routes = self.core.tripSession().currentNavigationRoutes {
                    self.presentPhone(routes: routes, fromCarPlay: true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// iPhone-App kommt in den Vordergrund, während CarPlay navigiert, die Fahrt auf dem iPhone aber nicht zu sehen ist.
    /// Fall: CarPlay hat Meeterz frisch gestartet (App war ganz geschlossen) – dann gab es beim Start der Route noch
    /// gar kein iPhone-Fenster, in dem die Navigation hätte erscheinen können. Jetzt nachholen.
    func showCarPlayDriveOnPhoneIfNeeded() {
        guard isNavigating, phoneController == nil, CarPlayController.shared.isConnected,
              let routes = core.tripSession().currentNavigationRoutes else { return }
        Diag.log("iPhone geöffnet während CarPlay-Fahrt – zeige Navigation auch hier")
        preview = nil
        presentPhone(routes: routes, fromCarPlay: true)
    }

    /// Zwischenstopp (z. B. Treffpunkt) in die laufende Navigation einfügen
    func addStop(_ stop: Place) async {
        guard isNavigating, let destination else {
            await planRoute(to: stop)
            return
        }
        guard let routes = await calculate(to: destination, via: [stop], mode: activeMode) else { return }
        core.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)
        AppModel.shared.show(String(localized: "\(stop.name) als Zwischenstopp hinzugefügt."), isError: false)
    }

    /// Kartenart während der iPhone-Navigation sofort übernehmen (vorher galt sie erst bei der nächsten Route)
    func applyMapStyle() {
        guard let controller = phoneController else { return }
        controller.styleManager.styles = NavigationStyles.phone()
        if let mapView = controller.navigationMapView?.mapView {
            Satellite3DBuildings.install(on: mapView, satellite: UserDefaults.standard.object(forKey: "map.satellite") as? Bool ?? true)
        }
        Diag.log("iPhone-Navigation: Kartenstil gewechselt (Satellit=\(UserDefaults.standard.bool(forKey: "map.satellite")))")
    }

    /// Ohne Route, ohne CarPlay und im Hintergrund braucht niemand Mapbox' Ortung – anhalten spart Akku
    func idleIfUnused() {
        guard !isNavigating, !CarPlayController.shared.isConnected,
              UIApplication.shared.applicationState == .background else { return }
        navigationProvider.tripSession().setToIdle()
    }

    func stop() {
        guard isNavigating || phoneController != nil else { return }
        subscriptions.removeAll()
        overlay?.stop()
        overlay = nil
        recenterTask?.cancel()
        recenterTask = nil
        signTimer?.invalidate()
        signTimer = nil
        RightOfWaySigns.shared.hideAll()
        // Ursache für „Karte bleibt nach dem Beenden komplett stehen“ (CarPlay, 27.10.): setToIdle schaltet Mapbox' Ortung
        // ganz ab. Die CarPlay-Karte bekommt ihren Standort aber genau daher – Pfeil und Kamera froren ein, bis die
        // nächste Route startete. Mit CarPlay darum in die freie Fahrt wechseln (Karte folgt weiter), sonst wie bisher
        // ganz anhalten (spart auf dem iPhone Akku).
        // Gilt genauso auf dem iPhone (z. B. zu Fuß), solange die App im Vordergrund ist; erst im Hintergrund ohne
        // CarPlay wird angehalten (siehe idleIfUnused).
        //
        // Reihenfolge wichtig (Karte stand am 28.10. trotzdem wieder): Mapbox' NavigationViewController schaltet beim
        // Schließen selbst auf Leerlauf, sofern noch „aktive Führung“ gilt. Der Wechsel in die freie Fahrt meldet den
        // neuen Zustand aber erst verzögert (nach dem Entfernen der Route) – das Schließen danach sah also noch
        // „aktive Führung“, schaltete die Ortung ab, und die freie Fahrt lief ohne Standort weiter. Darum zuerst das
        // iPhone-Navigationsbild schließen, danach den Zustand setzen.
        phoneController?.dismiss(animated: true)
        phoneController = nil
        if CarPlayController.shared.isConnected || UIApplication.shared.applicationState != .background {
            navigationProvider.tripSession().startFreeDrive()
            Diag.log("Navigation beendet – Mapbox in freier Fahrt (\(CarPlayController.shared.isConnected ? "CarPlay verbunden" : "App im Vordergrund"))")
        } else {
            navigationProvider.tripSession().setToIdle()
        }
        // Prüfen statt raten: in welchem Zustand ist Mapbox kurz danach (soll freie Fahrt sein, nicht Leerlauf)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            Diag.log("Mapbox-Zustand 3 s nach dem Beenden: \(navigationProvider.tripSession().currentSession.state)")
        }
        isNavigating = false
        ChargeMonitor.shared.stop()
        NavigationLiveActivityController.shared.end()
        AppModel.shared.location.setNavigating(false)
        destination = nil
        eta = nil
        remaining = nil
        announcedArrival = [:]
        Task { await AppModel.shared.routes.clearMine() }
    }

    // MARK: Route teilen

    private func beginTracking() {
        isNavigating = true
        ChargeMonitor.shared.start()
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

        // Live-Aktivität (Sperrbildschirm, Dynamic Island): Abbiegung und Ankunft alle paar Sekunden
        NavigationLiveActivityController.shared.start(destinationName: destination?.name,
                                                      destination: destination?.coordinate)
        core.navigation().routeProgress
            .compactMap { $0?.routeProgress }
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { progress in
                Task { @MainActor in NavigationLiveActivityController.shared.update(progress) }
            }
            .store(in: &subscriptions)

        // Unfälle, Sperrungen, schwere Staus voraus (einmal je Ereignis)
        IncidentWatcher.shared.reset()
        core.navigation().routeProgress
            .compactMap { $0?.routeProgress }
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { progress in
                Task { @MainActor in IncidentWatcher.shared.check(progress) }
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
        checkDelay(eta: arrival)
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

    // MARK: Verspätung automatisch melden

    /// Zuletzt mitgeteilte Ankunft je Treffen (am Anfang die erste berechnete)
    @ObservationIgnored private var announcedArrival: [UUID: Date] = [:]

    /// Fährt man zu einem vereinbarten Treffpunkt und verschiebt sich die Ankunft um 5 Minuten oder mehr,
    /// bekommt der Freund automatisch eine Nachricht. Danach gilt die neue Zeit als Maßstab.
    private func checkDelay(eta: Date) {
        guard MessagesStore.autoDelay, let destination else { return }
        for meetup in AppModel.shared.meetups.accepted
        where meetup.coordinate.distance(to: destination.coordinate) < 300 {
            guard let before = announcedArrival[meetup.id] else {
                announcedArrival[meetup.id] = eta
                continue
            }
            let late = eta.timeIntervalSince(before)
            guard late >= 5 * 60 else { continue }
            announcedArrival[meetup.id] = eta
            let minutes = Int((late / 60).rounded())
            let text = String(localized: "Ich komme ca. \(minutes) Min. später – neue Ankunft \(Format.time.string(from: eta))")
            Task { await AppModel.shared.messages.send(text, to: [meetup.otherId], meetupId: meetup.id, automatic: true) }
            Diag.log("Verspätung gemeldet an \(meetup.otherName): +\(minutes) Min.")
        }
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
            return String(localized: "Das Navigationskontingent ist für diesen Monat aufgebraucht.")
        }
        if text.contains("offline") || text.contains("internet") {
            return String(localized: "Keine Internetverbindung – Route kann nicht berechnet werden.")
        }
        return String(localized: "Route konnte nicht berechnet werden.")
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
    case fifteenMinutes, oneHour, untilArrival, always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: String(localized: "15 Min.")
        case .oneHour: String(localized: "1 Std.")
        case .untilArrival: String(localized: "Bis Ankunft")
        case .always: String(localized: "Immer")
        }
    }

    /// Ende des Teilens; „Bis Ankunft“ ohne laufende Fahrt bleibt offen, bis die nächste Fahrt startet
    func until(eta: Date?) -> Date? {
        switch self {
        case .fifteenMinutes: Date().addingTimeInterval(15 * 60)
        case .oneHour: Date().addingTimeInterval(3600)
        case .untilArrival: eta.map { $0.addingTimeInterval(15 * 60) }
        case .always: nil
        }
    }

    /// Beschreibung für Fußzeile und Siri
    var explanation: String {
        switch self {
        case .fifteenMinutes: String(localized: "Das Teilen endet automatisch nach 15 Minuten.")
        case .oneHour: String(localized: "Das Teilen endet automatisch nach einer Stunde.")
        case .untilArrival: String(localized: "Das Teilen endet 15 Minuten nach der Ankunft deiner nächsten Fahrt.")
        case .always: String(localized: "Freunde sehen dich, bis du das Teilen pausierst.")
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
