import Combine
import CoreLocation
import MapboxNavigationCore

/// Live-Standort für Mapbox mit Plausibilitätsprüfung: Steht man (z. B. an der Ampel) und das GPS springt durch
/// Spiegelungen an Häusern um 20–50 m, hielt Mapbox das für „von der Route abgekommen“ und rechnete immer wieder neu
/// (21.11.). Ein Sprung, der schneller wäre als das Auto fährt, wird verworfen – die letzte gute Position gilt weiter.
/// Bleibt der neue Ort länger als 10 s bestehen, war es keine Störung, dann wird er übernommen.
/// Dazu: im Stand Position und Richtung fest (kein Vor- und Zurückkriechen), Messungen hinter der Fahrtrichtung und
/// Nachzügler verworfen (kein „rückwärts fahren“), langsam die letzte verlässliche Richtung.
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

    /// Unterschied zweier Richtungen in Grad (0–180)
    static func angle(_ a: CLLocationDirection, _ b: CLLocationDirection) -> CLLocationDirection {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    /// Liegt der neue Ort hinter dem alten, obwohl man vorwärts fährt? (Richtung des Wegs gegen die Fahrtrichtung)
    static func behind(from last: CLLocationCoordinate2D, to new: CLLocationCoordinate2D, course: CLLocationDirection) -> Bool {
        let dLat = new.latitude - last.latitude
        let dLng = (new.longitude - last.longitude) * cos(last.latitude * .pi / 180)
        let bearing = (atan2(dLng, dLat) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return angle(bearing, course) > 120
    }

    /// Letzte verlässliche Fahrtrichtung (aus einer Messung in Fahrt)
    private var goodCourse: CLLocationDirection?

    private func filtered(_ location: CLLocation) -> CLLocation {
        guard location.horizontalAccuracy >= 0 else { return location }
        // Richtung nur aus Fahrt mit sicherer Richtung merken – langsam ist die GPS-Richtung Zufall
        if location.speed >= 3, location.course >= 0, location.courseAccuracy >= 0, location.courseAccuracy < 30 {
            goodCourse = location.course
        }
        guard let last = accepted else {
            accepted = location
            return location
        }
        // Nachzügler (älter als die letzte Messung) nie verwenden – sie ließen den Pfeil zurückspringen
        guard location.timestamp > last.timestamp else { return held(last, now: location, standing: false) }
        let distance = location.distance(from: last)
        let seconds = location.timestamp.timeIntervalSince(last.timestamp)
        let tooLong = heldSince.map { Date().timeIntervalSince($0) > 10 } ?? false

        // Stillstand (an der Ampel): Position und Richtung festhalten, Tempo 0 – sonst kroch der Pfeil durch das
        // Rauschen vor und zurück und drehte sich (21.11.: „rollt weiter und dann wieder zurück“)
        if location.speed >= 0, location.speed < 0.8, distance < 25, !tooLong {
            return held(last, now: location, standing: true)
        }
        var reason: String?
        if !Self.plausible(distance: distance, seconds: seconds, speed: location.speed) {
            reason = "Sprung"
        } else if location.speed >= 3, distance > 10, let course = goodCourse,
                  Self.behind(from: last.coordinate, to: location.coordinate, course: course) {
            // Vorwärts unterwegs, aber die Messung liegt hinter der letzten: wirkte wie rückwärts fahren
            reason = "rückwärts"
        }
        if reason == nil || tooLong {
            if tooLong { Diag.log("GPS: neuer Ort nach 10 s übernommen (\(Int(distance)) m)") }
            heldSince = nil
            accepted = location
            return withSteadyCourse(location)
        }
        if heldSince == nil {
            heldSince = Date()
            Diag.log("GPS-\(reason!) verworfen: \(Int(distance)) m in \(String(format: "%.1f", seconds)) s bei \(Int(max(location.speed, 0) * 3.6)) km/h (±\(Int(location.horizontalAccuracy)) m)")
        }
        return held(last, now: location, standing: false)
    }

    /// Langsam (unter 2 m/s) die letzte verlässliche Richtung statt der zufälligen GPS-Richtung
    private func withSteadyCourse(_ location: CLLocation) -> CLLocation {
        guard location.speed < 2, let course = goodCourse else { return location }
        return CLLocation(coordinate: location.coordinate, altitude: location.altitude,
                          horizontalAccuracy: location.horizontalAccuracy, verticalAccuracy: location.verticalAccuracy,
                          course: course, courseAccuracy: 10,
                          speed: location.speed, speedAccuracy: location.speedAccuracy, timestamp: location.timestamp)
    }

    /// Letzte gute Position mit aktueller Zeit (im Stand mit Tempo 0)
    private func held(_ last: CLLocation, now: CLLocation, standing: Bool) -> CLLocation {
        CLLocation(coordinate: last.coordinate, altitude: last.altitude,
                   horizontalAccuracy: last.horizontalAccuracy, verticalAccuracy: last.verticalAccuracy,
                   course: goodCourse ?? last.course, courseAccuracy: goodCourse == nil ? last.courseAccuracy : 10,
                   speed: standing ? 0 : now.speed, speedAccuracy: now.speedAccuracy,
                   timestamp: max(now.timestamp, last.timestamp.addingTimeInterval(0.001)))
    }
}
