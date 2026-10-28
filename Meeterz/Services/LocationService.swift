import CoreLocation
import Observation
import UIKit

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
    /// Wird das Teilen von selbst wieder anspringen (z. B. Inkognito mit Ablaufzeit)? Dann bleibt im Hintergrund
    /// die sparsame Ortswechsel-Überwachung an, damit die App danach von selbst wieder sendet.
    @ObservationIgnored var mayResumeSharing: () -> Bool = { false }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var started = false
    /// Beim Start im Hintergrund (z. B. durch einen stillen Push) zählt die App nicht als sichtbar
    @ObservationIgnored private var inForeground = UIApplication.shared.applicationState != .background
    @ObservationIgnored private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    @ObservationIgnored private var navigating = false
    @ObservationIgnored private var carPlay = false
    @ObservationIgnored private var lastMovingAt = Date.distantPast
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    /// Ab dieser Geschwindigkeit (m/s, ≈ 7 km/h) gilt man als „unterwegs“
    private static let movingSpeed = 2.0
    /// So lange (Sekunden) nach der letzten Bewegung bleibt der Unterwegs-Modus aktiv
    private static let settleAfter: TimeInterval = 30

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

    /// Wie oft die App schon nach „Immer“ gefragt hat. iOS zeigt den Dialog höchstens einmal;
    /// danach hilft nur der Weg über die Einstellungen.
    private static let askedKey = "loc.alwaysAsked"
    var alwaysAskedBefore: Bool { UserDefaults.standard.integer(forKey: Self.askedKey) > 0 }

    /// Upgrade auf "Immer": beim ersten Mal über den Systemdialog, danach direkt in die Einstellungen.
    func requestAlways() {
        let asked = UserDefaults.standard.integer(forKey: Self.askedKey)
        UserDefaults.standard.set(asked + 1, forKey: Self.askedKey)
        if asked == 0 {
            manager.requestAlwaysAuthorization()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Einmalige aktuelle Position, z. B. wenn ein Freund per stillem Push danach fragt.
    func currentFix(timeout: TimeInterval) async -> CLLocation? {
        if let last = lastLocation, Date().timeIntervalSince(last.timestamp) < 20, last.horizontalAccuracy < 100 { return last }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return nil }
        return await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolveWaiters(with: nil)
            }
        }
    }

    private func resolveWaiters(with location: CLLocation?) {
        let waiting = fixWaiters
        fixWaiters = []
        waiting.forEach { $0.resume(returning: location) }
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
        let wasConnected = carPlay
        carPlay = value
        if wasConnected && !value {
            // CarPlay getrennt = ausgestiegen: letzten Parkplatz noch melden, dann sofort in den Spar-Modus
            if let last = lastLocation { onUpdate?(last) }
            lastMovingAt = .distantPast
        }
        apply()
    }

    /// Nach Änderungen an Teilen/Inkognito neu bewerten
    func refreshMode() { apply() }

    // MARK: Modus

    private func start() {
        started = true
        manager.allowsBackgroundLocationUpdates = true
        apply()
    }

    private func desiredMode() -> Mode {
        if inForeground || navigating || carPlay { return .full }
        if !isSharing() { return (mayResumeSharing() && canShareInBackground) ? .saving : .off }
        if !canShareInBackground { return .off }
        if Date().timeIntervalSince(lastMovingAt) < Self.settleAfter { return .moving }
        // Ohne „Immer“ gibt es im Hintergrund keine Ortswechsel-Meldungen. Dauerhaft weiterzuorten
        // würde den Akku leeren und die Ortungsanzeige in der Dynamic Island dauernd zeigen – also aus.
        return canShareInBackground ? .saving : .off
    }

    private func apply() {
        guard started else { return }
        let target = desiredMode()
        // Im Modus „voll“ trotzdem neu einstellen: Auto/Navigation brauchen mehr als die Karte im Vordergrund
        guard target != mode || target == .full else { return }
        mode = target

        switch target {
        case .full:
            manager.showsBackgroundLocationIndicator = true       // Navigation/CarPlay im Hintergrund: Anzeige ist gewollt
            manager.stopMonitoringSignificantLocationChanges()
            if navigating || carPlay {
                // Im Auto wie ein Navi: höchste Genauigkeit (GPS + Sensoren), jede Änderung melden
                manager.activityType = .automotiveNavigation
                manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
                manager.distanceFilter = kCLDistanceFilterNone
                requestPreciseIfReduced()
            } else {
                manager.activityType = .otherNavigation
                manager.desiredAccuracy = kCLLocationAccuracyBest
                manager.distanceFilter = 10
            }
            manager.startUpdatingLocation()
        case .moving:
            manager.showsBackgroundLocationIndicator = false
            manager.stopMonitoringSignificantLocationChanges()
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 50
            manager.startUpdatingLocation()
            scheduleSettleCheck()
        case .saving:
            manager.showsBackgroundLocationIndicator = false
            manager.stopUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
        case .off:
            manager.showsBackgroundLocationIndicator = false
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
        }
        keepRelaunchHook()
    }

    /// Ortswechsel-Überwachung immer an lassen (mit „Immer“-Erlaubnis): Sie ist der einzige Weg, auf dem iOS eine
    /// weggewischte App von selbst wieder startet – sobald man ein Stück fährt. Ohne sie blieb Meeterz nach dem
    /// Wegwischen aus, und das CarPlay-Dashboard zeigte nur einen Platzhalter (28.10.). Kostet praktisch keinen Akku
    /// und blendet keine Ortungsanzeige ein. In „aus“ werden die Meldungen nicht weitergegeben (kein Teilen).
    private func keepRelaunchHook() {
        if authorization == .authorizedAlways {
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    /// Hat der Nutzer nur „ungefähren Standort“ erlaubt, für die Fahrt um präzisen Standort bitten
    private func requestPreciseIfReduced() {
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        Diag.log("Standort: nur ungefähr erlaubt – frage nach präzisem Standort")
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "LocationAccuracyAuthorizationDescription")
    }

    /// Prüft später, ob man zur Ruhe gekommen ist, und schaltet dann in den sparsamen Modus zurück.
    private func scheduleSettleCheck() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            // Solange noch Bewegung war, bis 30 Sekunden nach der letzten Bewegung warten – dann erst zurückschalten.
            // (Im Stand kommen wegen des Distanzfilters keine Updates, die sonst neu bewerten würden.)
            while let self, !Task.isCancelled {
                let remaining = Self.settleAfter - Date().timeIntervalSince(self.lastMovingAt)
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(remaining + 5))
            }
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
            // Direkt nach der ersten Erlaubnis um „Immer“ bitten (zeigt iOS zu einem passenden Zeitpunkt)
            if status == .authorizedWhenInUse, !self.alwaysAskedBefore { self.requestAlways() }
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
            self.recordTrack(loc)
            ParkingDetector.shared.record(loc)
            self.resolveWaiters(with: loc)
            if loc.speed > Self.movingSpeed {
                self.lastMovingAt = Date()
                // Aus dem sparsamen Modus aufwachen, sobald man sich zügig bewegt
                if self.mode == .saving { self.apply() }
            }
            // Teilen aus: Meldungen der Ortswechsel-Überwachung (nur noch für den Neustart da) nicht weitergeben
            guard self.mode != .off else { return }
            self.onUpdate?(loc)
        }
    }

    // MARK: Eigene Spur (für den zeitgleichen Vergleich mit Freundespositionen)

    /// Eigene Positionen der letzten 15 Minuten. Freundespositionen kommen verzögert an –
    /// verglichen wird darum mit der Stelle, an der ich zu *deren* Zeitpunkt war, nicht mit jetzt.
    @ObservationIgnored private var track: [CLLocation] = []

    private func recordTrack(_ loc: CLLocation) {
        if let last = track.last, loc.timestamp <= last.timestamp { return }
        track.append(loc)
        let cutoff = loc.timestamp.addingTimeInterval(-15 * 60)
        if let first = track.first, first.timestamp < cutoff { track.removeAll { $0.timestamp < cutoff } }
    }

    /// Wo war ich zum Zeitpunkt `date`? Zwischen zwei Meldungen linear eingepasst; nil, wenn dort eine Lücke > 20 s ist.
    func location(at date: Date) -> CLLocation? {
        guard let i = track.firstIndex(where: { $0.timestamp >= date }) else {
            if let last = track.last, date.timeIntervalSince(last.timestamp) < 10 { return last }
            return nil
        }
        let b = track[i]
        guard i > 0 else { return b.timestamp.timeIntervalSince(date) < 10 ? b : nil }
        let a = track[i - 1]
        let span = b.timestamp.timeIntervalSince(a.timestamp)
        guard span < 20 else { return nil }
        let t = span > 0 ? date.timeIntervalSince(a.timestamp) / span : 0
        return CLLocation(coordinate: .init(latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * t,
                                            longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * t),
                          altitude: 0, horizontalAccuracy: max(a.horizontalAccuracy, b.horizontalAccuracy), verticalAccuracy: -1,
                          course: t < 0.5 ? a.course : b.course, speed: a.speed + (b.speed - a.speed) * t, timestamp: date)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Temporäre Fehler (z. B. kein Fix im Tunnel) ignorieren – CoreLocation versucht es weiter.
    }
}
