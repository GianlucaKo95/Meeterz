import CoreLocation
import Observation

/// Eigener Standort – akkuschonend:
///  • voll (GPS, alle 10 m): App im Vordergrund, Navigation oder CarPlay
///  • unterwegs (reduziert, alle ~50 m): im Hintergrund, solange man sich bewegt
///  • sparsam (nur große Ortswechsel): im Hintergrund, wenn man steht (braucht „Immer“)
///  • aus: im Hintergrund, wenn man nichts teilt (Inkognito, Teilen pausiert)
@MainActor @Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Mode: Equatable { case full, moving, saving, off }

    private(set) var authorization: CLAuthorizationStatus
    private(set) var lastLocation: CLLocation?
    private(set) var mode: Mode = .off

    @ObservationIgnored var onUpdate: ((CLLocation) -> Void)?
    /// Wird beim Wechsel in den Hintergrund gefragt: Soll der Standort überhaupt geteilt werden?
    @ObservationIgnored var isSharing: () -> Bool = { true }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var inForeground = true
    @ObservationIgnored private var navigating = false
    @ObservationIgnored private var carPlay = false
    @ObservationIgnored private var lastMovingAt = Date.distantPast
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    /// Ab dieser Geschwindigkeit (m/s, ≈ 7 km/h) gilt man als „unterwegs“
    private static let movingSpeed = 2.0
    /// So lange nach der letzten Bewegung bleibt der Unterwegs-Modus aktiv
    private static let settleAfter: TimeInterval = 5 * 60

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    var canShareInBackground: Bool { authorization == .authorizedAlways }

    func requestPermission() {
        switch authorization {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: start()
        default: break
        }
    }

    /// Upgrade auf "Immer" – iOS zeigt den Dialog nur einmal.
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    // MARK: Zustand von außen

    func setForeground(_ value: Bool) {
        inForeground = value
        apply()
    }

    func setNavigating(_ value: Bool) {
        navigating = value
        apply()
    }

    func setCarPlay(_ value: Bool) {
        carPlay = value
        apply()
    }

    /// Nach Änderungen an Teilen/Inkognito neu bewerten
    func refreshMode() { apply() }

    // MARK: Modus

    private func start() {
        started = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        apply()
    }

    private func desiredMode() -> Mode {
        if inForeground || navigating || carPlay { return .full }
        if !isSharing() { return .off }
        if Date().timeIntervalSince(lastMovingAt) < Self.settleAfter { return .moving }
        // Ohne „Immer“ liefert iOS im Hintergrund keine Ortswechsel-Meldungen – dann reduziert weiterlaufen
        return canShareInBackground ? .saving : .moving
    }

    private func apply() {
        guard started else { return }
        let target = desiredMode()
        guard target != mode else { return }
        mode = target

        switch target {
        case .full:
            manager.stopMonitoringSignificantLocationChanges()
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 10
            manager.startUpdatingLocation()
        case .moving:
            manager.stopMonitoringSignificantLocationChanges()
            manager.desiredAccuracy = canShareInBackground ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
            manager.distanceFilter = canShareInBackground ? 50 : 100
            manager.startUpdatingLocation()
            scheduleSettleCheck()
        case .saving:
            manager.stopUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
        case .off:
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    /// Prüft später, ob man zur Ruhe gekommen ist, und schaltet dann in den sparsamen Modus zurück.
    private func scheduleSettleCheck() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleAfter + 5))
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.started ? self.reapply() : self.start()
            }
        }
    }

    /// Nach Berechtigungswechsel („Immer“ erteilt) die Einstellungen des aktuellen Modus neu setzen
    private func reapply() {
        mode = .off
        apply()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else { return }
        Task { @MainActor in
            self.lastLocation = loc
            if loc.speed > Self.movingSpeed {
                self.lastMovingAt = Date()
                // Aus dem sparsamen Modus aufwachen, sobald man sich zügig bewegt
                if self.mode == .saving { self.apply() }
            }
            self.onUpdate?(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Temporäre Fehler (z. B. kein Fix im Tunnel) ignorieren – CoreLocation versucht es weiter.
    }
}
