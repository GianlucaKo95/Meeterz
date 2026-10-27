import Foundation
import Combine
import CarPlay
import CoreLocation
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit

/// Zwei Korrekturen an der CarPlay-Navigation von Mapbox:
///
/// 1. **Abbiegeanzeige springt** (400 m → 4 km / 650 m, oft genau wenn die Ansage beginnt):
///    Mapbox baut bei jedem neuen Hinweis-Banner (kommt meist zusammen mit der Ansage) die Abbiegekarte neu und
///    setzt als Start-Entfernung die **gesamte Länge des Abschnitts** (`step.distance`) statt der Reststrecke.
///    Erst beim nächsten Fortschritt wird es korrigiert. Wir setzen direkt danach die richtige Reststrecke.
///
/// 2. **Kein Heranzoomen vor Abbiegungen/Ausfahrten**: Mapbox' Folgekamera rahmt den Zoom nach Tempo und Strecke,
///    zoomt vor dem Manöver aber oft nicht nah genug. Nähert man sich einer Abbiegung oder Ausfahrt, zoomt Meeterz
///    auf mindestens Zoom 16,5 (bei Ausfahrt) bzw. 17 – nur wenn die Karte nicht schon so nah ist – und gibt den
///    Zoom nach dem Manöver an Mapbox zurück. Hat der Fahrer selbst gezoomt, bleibt sein Zoom.
@MainActor
final class ManeuverGuidance {
    static let shared = ManeuverGuidance()

    private var subscriptions = Set<AnyCancellable>()
    private weak var navigationController: CarPlayNavigationViewController?
    /// Gerade herangezoomt (für welches Manöver)
    private var zoomedFor: Int?
    /// Gerade vor einem Manöver herangezoomt
    var isZoomed: Bool { zoomedFor != nil }
    /// Wird gerufen, um den Zoom zu setzen (nil = wieder automatisch)
    var applyZoom: ((Double?) -> Void)?
    /// Hat der Fahrer selbst gezoomt? Dann nichts tun.
    var userZoomed: () -> Bool = { false }

    func start(_ controller: CarPlayNavigationViewController) {
        stop()
        navigationController = controller
        let core = navigationProvider.mapboxNavigation
        core.navigation().bannerInstructions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Nach Mapbox' eigenem Neuaufbau der Abbiegekarte (gleicher Auslöser) – darum einen Takt später
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.fixManeuverDistance() } }
            }
            .store(in: &subscriptions)
        core.navigation().routeProgress
            .compactMap { $0?.routeProgress }
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] progress in MainActor.assumeIsolated { self?.updateZoom(progress) } }
            .store(in: &subscriptions)
    }

    func stop() {
        subscriptions.removeAll()
        if zoomedFor != nil { applyZoom?(nil) }
        zoomedFor = nil
        navigationController = nil
    }

    // MARK: 1. Entfernung auf der Abbiegekarte

    private func fixManeuverDistance() {
        guard let controller = navigationController,
              let session = Mirror(reflecting: controller).descendant("carSession") as? CPNavigationSession,
              let maneuver = session.upcomingManeuvers.first,
              let step = navigationProvider.mapboxNavigation.navigation().currentRouteProgress?.routeProgress
                .currentLegProgress.currentStepProgress
        else { return }
        let measurement = Measurement(value: step.distanceRemaining, unit: UnitLength.meters)
        let formatted = Self.rounded(measurement)
        session.updateEstimates(CPTravelEstimates(distanceRemaining: formatted, timeRemaining: step.durationRemaining),
                                for: maneuver)
    }

    /// Wie CarPlay es erwartet: unter 1 km in Metern (gerundet), darüber in km
    private static func rounded(_ m: Measurement<UnitLength>) -> Measurement<UnitLength> {
        let meters = m.converted(to: .meters).value
        if meters >= 1_000 { return Measurement(value: (meters / 100).rounded() / 10, unit: .kilometers) }
        let step: Double = meters > 300 ? 50 : (meters > 100 ? 25 : 10)
        return Measurement(value: (meters / step).rounded() * step, unit: .meters)
    }

    // MARK: 2. Heranzoomen vor dem Manöver

    private func updateZoom(_ progress: RouteProgress) {
        guard !userZoomed() else {
            if zoomedFor != nil { zoomedFor = nil }
            return
        }
        let leg = progress.currentLegProgress
        let stepProgress = leg.currentStepProgress
        let index = leg.stepIndex
        guard let upcoming = leg.upcomingStep else { release(); return }
        let speed = max(navigationProvider.mapboxNavigation.navigation().currentLocationMatching?.enhancedLocation.speed ?? 0, 0)
        let exit = [.takeOffRamp, .reachFork].contains(upcoming.maneuverType)
        let turn = [.turn, .reachEnd, .takeRoundabout, .takeRotary, .takeOffRamp, .reachFork].contains(upcoming.maneuverType)
        // Rechtzeitig: ca. 12 s vor dem Manöver, mindestens 250 m, bei Ausfahrten mindestens 600 m
        let lead = max(speed * 12, exit ? 600 : 250)
        if turn, stepProgress.distanceRemaining < lead {
            let target = exit ? 16.5 : 17.0
            if zoomedFor != index {
                zoomedFor = index
                applyZoom?(target)   // setzt nur, wenn die Karte weiter weg ist (siehe CarPlayController)
            }
        } else if zoomedFor != nil, zoomedFor != index {
            // Manöver vorbei (neuer Abschnitt): Zoom wieder Mapbox überlassen
            release()
        }
    }

    private func release() {
        guard zoomedFor != nil else { return }
        zoomedFor = nil
        applyZoom?(nil)
    }
}
