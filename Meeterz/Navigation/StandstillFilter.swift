import Foundation
import Combine
import CoreLocation
import MapboxNavigationCore

/// Hält die Position im Stand fest, bevor sie Mapbox erreicht.
///
/// An der Ampel steht man 10–20 m vor dem Abbiegepunkt (Kreuzungsmitte). Im Stand springt die GPS-Position, und
/// schob sie den Pfeil über diesen Punkt, wechselte Mapbox zum nächsten Abschnitt – neue Anzeige und Ansage, obwohl
/// man noch nicht abgebogen war (10.11.). Darum: Steht das Auto (zwei Meldungen unter ~4 km/h), bleibt die Position
/// auf dem Haltepunkt stehen. Freigegeben wird erst, wenn das Auto wirklich fährt – zwei Meldungen hintereinander
/// über ~5 km/h (gut 1 s) – oder sich sehr weit entfernt hat (Tiefgarage, Fähre, langes Funkloch).
struct StandstillFilter {
    /// Darunter (m/s) gilt eine Meldung als „steht“
    static let standing: CLLocationSpeed = 1.0
    /// Darüber (m/s) gilt eine Meldung als „fährt“
    static let moving: CLLocationSpeed = 1.5
    /// So viele Meldungen hintereinander, bis der Zustand wechselt (GPS meldet etwa jede Sekunde)
    static let confirmations = 2
    /// So weit weg vom Haltepunkt (m) wird in jedem Fall freigegeben
    static let release: CLLocationDistance = 40

    private var anchor: CLLocation?
    private var standingCount = 0
    private var movingCount = 0
    private(set) var frozen = false

    /// Die Meldung, die Mapbox bekommt
    mutating func filter(_ loc: CLLocation) -> CLLocation {
        if frozen, let anchor {
            let away = loc.distance(from: anchor)
            movingCount = (loc.speed >= Self.moving || (loc.speed < 0 && away > 15)) ? movingCount + 1 : 0
            if movingCount >= Self.confirmations || away > Self.release {
                frozen = false
                standingCount = 0
                movingCount = 0
                self.anchor = nil
                return loc
            }
            return Self.held(anchor, at: loc)
        }
        standingCount = (loc.speed >= 0 && loc.speed < Self.standing) ? standingCount + 1 : 0
        if standingCount >= Self.confirmations {
            frozen = true
            anchor = loc
            movingCount = 0
            return Self.held(loc, at: loc)
        }
        return loc
    }

    /// Haltepunkt mit der Zeit (und Genauigkeit) der neuen Meldung, Tempo 0, Fahrtrichtung vom Anhalten
    private static func held(_ anchor: CLLocation, at loc: CLLocation) -> CLLocation {
        CLLocation(coordinate: anchor.coordinate, altitude: anchor.altitude,
                   horizontalAccuracy: loc.horizontalAccuracy, verticalAccuracy: anchor.verticalAccuracy,
                   course: anchor.course, courseAccuracy: anchor.courseAccuracy,
                   speed: 0, speedAccuracy: max(loc.speedAccuracy, 0), timestamp: loc.timestamp)
    }
}

/// Standortquelle für Mapbox wie dessen eigene (`LocationClient.liveValue`), nur mit StandstillFilter dazwischen
@MainActor
final class FilteredLocationSource: NSObject, CLLocationManagerDelegate {
    static let shared = FilteredLocationSource()

    private let manager = CLLocationManager()
    private let locations = PassthroughSubject<CLLocation, Never>()
    private let headings = PassthroughSubject<CLHeading, Never>()
    nonisolated(unsafe) private var filter = StandstillFilter()
    nonisolated(unsafe) private var wasFrozen = false

    override private init() {
        super.init()
        manager.requestWhenInUseAuthorization()
        if (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.delegate = self
    }

    var client: LocationClient {
        LocationClient(
            locations: locations.eraseToAnyPublisher(),
            headings: headings.eraseToAnyPublisher(),
            startUpdatingLocation: { [manager] in manager.startUpdatingLocation() },
            stopUpdatingLocation: { [manager] in manager.stopUpdatingLocation() },
            startUpdatingHeading: { [manager] in manager.startUpdatingHeading() },
            stopUpdatingHeading: { [manager] in manager.stopUpdatingHeading() }
        )
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let raw = locations.last else { return }
        let out = filter.filter(raw)
        if filter.frozen != wasFrozen {
            wasFrozen = filter.frozen
            let text = filter.frozen ? "Stand erkannt – Position für die Navigation festgehalten"
                : "Fährt wieder – Position freigegeben (\(Int(max(raw.speed, 0) * 3.6)) km/h)"
            Task { @MainActor in Diag.log(text) }
        }
        self.locations.send(out)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        headings.send(newHeading)
    }
}
