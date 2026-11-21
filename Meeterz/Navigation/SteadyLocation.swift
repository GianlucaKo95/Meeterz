import Combine
import CoreLocation
import MapboxNavigationCore

/// Live-Standort für Mapbox mit Plausibilitätsprüfung: Steht man (z. B. an der Ampel) und das GPS springt durch
/// Spiegelungen an Häusern um 20–50 m, hielt Mapbox das für „von der Route abgekommen“ und rechnete immer wieder neu
/// (21.11.). Ein Sprung, der schneller wäre als das Auto fährt, wird verworfen – die letzte gute Position gilt weiter.
/// Bleibt der neue Ort länger als 10 s bestehen, war es keine Störung, dann wird er übernommen.
@MainActor
final class SteadyLocation: NSObject, CLLocationManagerDelegate {
    static let shared = SteadyLocation()

    private let manager = CLLocationManager()
    private let locations = PassthroughSubject<CLLocation, Never>()
    private let headings = PassthroughSubject<CLHeading, Never>()
    private var accepted: CLLocation?
    private var heldSince: Date?

    override private init() {
        super.init()
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String], modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.delegate = self
    }

    /// Für `CoreConfig(locationSource: .custom(...))`
    static var client: LocationClient {
        LocationClient(
            locations: shared.locations.eraseToAnyPublisher(),
            headings: shared.headings.eraseToAnyPublisher(),
            startUpdatingLocation: { MainActor.assumeIsolated { shared.manager.startUpdatingLocation() } },
            stopUpdatingLocation: { MainActor.assumeIsolated { shared.manager.stopUpdatingLocation() } },
            startUpdatingHeading: { MainActor.assumeIsolated { shared.manager.startUpdatingHeading() } },
            stopUpdatingHeading: { MainActor.assumeIsolated { shared.manager.stopUpdatingHeading() } }
        )
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { self.locations.send(self.filtered(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated { self.headings.send(newHeading) }
    }

    /// Weiter als das Auto in der Zeit fahren kann (Tempo + 8 m/s Spielraum, mindestens 15 m) = Störung
    static func plausible(distance: CLLocationDistance, seconds: TimeInterval, speed: CLLocationSpeed) -> Bool {
        distance <= max(15, (max(speed, 0) + 8) * max(seconds, 0.5))
    }

    private func filtered(_ location: CLLocation) -> CLLocation {
        guard let last = accepted, location.horizontalAccuracy >= 0 else {
            accepted = location
            return location
        }
        let distance = location.distance(from: last)
        let seconds = location.timestamp.timeIntervalSince(last.timestamp)
        let tooLong = heldSince.map { Date().timeIntervalSince($0) > 10 } ?? false
        if Self.plausible(distance: distance, seconds: seconds, speed: location.speed) || tooLong {
            if tooLong { Diag.log("GPS: neuer Ort nach 10 s übernommen (\(Int(distance)) m)") }
            heldSince = nil
            accepted = location
            return location
        }
        if heldSince == nil {
            heldSince = Date()
            Diag.log("GPS-Sprung verworfen: \(Int(distance)) m in \(String(format: "%.1f", seconds)) s bei \(Int(max(location.speed, 0) * 3.6)) km/h (±\(Int(location.horizontalAccuracy)) m)")
        }
        // Letzte gute Position, aber mit aktueller Zeit und Geschwindigkeit
        return CLLocation(coordinate: last.coordinate, altitude: last.altitude,
                          horizontalAccuracy: last.horizontalAccuracy, verticalAccuracy: last.verticalAccuracy,
                          course: last.course, courseAccuracy: last.courseAccuracy,
                          speed: location.speed, speedAccuracy: location.speedAccuracy, timestamp: location.timestamp)
    }
}
