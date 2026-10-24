import Foundation
import CoreLocation
import CoreMotion

/// Parken erkennen – nicht nur beim Trennen von CarPlay:
/// 1. Live-Daten vom Auto: meldet es „geparkt“ mit eigener GPS-Position, ist das der genaueste Platz.
/// 2. Bewegungssensoren des iPhones: Wechsel von „im Auto“ zu „zu Fuß“ – Platz = Standort beim Ende der Autofahrt.
@MainActor
final class ParkingDetector {
    static let shared = ParkingDetector()

    private let motion = CMMotionActivityManager()
    private var running = false
    /// Zuletzt gesehene Standorte (für die Position zum Zeitpunkt, als die Autofahrt endete)
    private var trail: [CLLocation] = []
    private var inCarSince: Date?
    private var lastCarActivity: Date?
    private var wasParked: Bool?

    func start() {
        guard ParkingStore.enabled, !running, CMMotionActivityManager.isActivityAvailable() else { return }
        running = true
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated { self?.handle(activity) }
        }
    }

    func stop() {
        guard running else { return }
        motion.stopActivityUpdates()
        running = false
        inCarSince = nil
    }

    /// Jeder neue Standort (aus dem LocationService)
    func record(_ location: CLLocation) {
        guard ParkingStore.enabled else { return }
        trail.append(location)
        let cutoff = Date().addingTimeInterval(-30 * 60)
        trail.removeAll { $0.timestamp < cutoff }
    }

    private func handle(_ a: CMMotionActivity) {
        guard a.confidence != .low else { return }
        if a.automotive {
            if inCarSince == nil { inCarSince = a.startDate }
            lastCarActivity = a.startDate
            return
        }
        // Nach mindestens 3 Minuten im Auto jetzt zu Fuß unterwegs → geparkt
        guard a.walking, let since = inCarSince, let lastCar = lastCarActivity,
              lastCar.timeIntervalSince(since) > 3 * 60 || Date().timeIntervalSince(since) > 3 * 60 else { return }
        inCarSince = nil
        // Position: letzter Standort, bevor man ausgestiegen ist (mit kleinem Puffer)
        let walkStart = a.startDate
        let spot = trail.last(where: { $0.timestamp <= walkStart.addingTimeInterval(20) })
            ?? AppModel.shared.location.lastLocation
        guard let spot else { return }
        Diag.log("Parken erkannt (Bewegung: Auto → zu Fuß)")
        AppModel.shared.parking.save(spot, source: "Bewegung")
    }

    /// Live-Daten vom Auto: Wechsel auf „geparkt“ mit Position
    func vehicleUpdate(_ status: VehicleStore.Status?) {
        guard ParkingStore.enabled, let status, let parked = status.parked else { return }
        defer { wasParked = parked }
        guard parked, wasParked == false, let lat = status.lat, let lng = status.lng, status.age < 15 * 60 else { return }
        let location = CLLocation(coordinate: .init(latitude: lat, longitude: lng), altitude: 0,
                                  horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: status.measuredAt)
        Diag.log("Parken erkannt (Auto meldet „geparkt“)")
        AppModel.shared.parking.save(location, source: "Auto")
    }
}
