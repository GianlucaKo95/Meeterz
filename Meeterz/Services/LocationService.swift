import CoreLocation
import Observation

/// Eigener Standort. Läuft auch im Hintergrund weiter (UIBackgroundModes: location).
@MainActor @Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus
    private(set) var lastLocation: CLLocation?

    @ObservationIgnored var onUpdate: ((CLLocation) -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.activityType = .automotiveNavigation
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

    private func start() {
        // Mit "Beim Verwenden" läuft es im Hintergrund weiter, solange es im Vordergrund gestartet wurde.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else { return }
        Task { @MainActor in
            self.lastLocation = loc
            self.onUpdate?(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Temporäre Fehler (z. B. kein Fix im Tunnel) ignorieren – CoreLocation versucht es weiter.
    }
}
