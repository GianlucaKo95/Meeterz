import Foundation
import MapboxDirections
import MapboxNavigationCore

/// Ansagen wie bei Apple Karten: „An der nächsten Ampel rechts abbiegen“, „Am zweiten Stoppschild links abbiegen“.
///
/// Mapbox liefert mit der Route je Kreuzung, ob dort eine Ampel oder ein Stoppschild steht. Liegt die Abbiegung an
/// einer Ampel (bzw. einem Stoppschild), zählen wir die Ampeln bis dorthin und formulieren die Ansage damit.
/// Nur für echte Abbiegungen, bis zur dritten Ampel und innerhalb von 800 m – sonst bleibt Mapbox' Ansage.
/// Die letzte Ansage direkt vor der Kreuzung („Jetzt rechts abbiegen“) bleibt unverändert.
enum LandmarkInstructions {
    enum Landmark { case trafficLight, stopSign }

    /// Neue Ansage oder nil (dann Mapbox' Text)
    static func rewrite(_ instruction: SpokenInstruction, legProgress: RouteLegProgress) -> String? {
        // Die Formulierung („An der nächsten Ampel …“) gibt es bisher nur auf Deutsch – sonst bleibt Mapbox' Ansage
        guard VoiceCatalog.language == "de" else { return nil }
        let stepProgress = legProgress.currentStepProgress
        guard let upcoming = legProgress.upcomingStep,
              [.turn, .reachEnd].contains(upcoming.maneuverType),
              let direction = directionText(upcoming.maneuverDirection),
              instruction.distanceAlongStep > 60,                         // nicht die „Jetzt …“-Ansage
              stepProgress.distanceRemaining < 800,
              !instruction.text.localizedCaseInsensitiveContains("ampel") else { return nil }

        // Kreuzungen vom aktuellen Standort bis einschließlich der Abbiegung
        let all = stepProgress.intersectionsIncludingUpcomingManeuverIntersection
            ?? ((legProgress.currentStep.intersections ?? []) + (upcoming.intersections?.prefix(1).map { $0 } ?? []))
        guard let maneuver = all.last else { return nil }
        let ahead = Array(all.dropLast().dropFirst(min(stepProgress.intersectionIndex + 1, max(all.count - 1, 0))))

        let landmark: Landmark
        if maneuver.trafficSignal == true { landmark = .trafficLight }
        else if maneuver.stopSign == true { landmark = .stopSign }
        else { return nil }

        let before = ahead.filter { landmark == .trafficLight ? $0.trafficSignal == true : $0.stopSign == true }.count
        let road = upcoming.names?.first.flatMap { $0.isEmpty ? nil : $0 }
        return phrase(landmark: landmark, ordinal: before + 1, direction: direction, road: road)
    }

    /// „An der nächsten Ampel rechts abbiegen auf Hauptstraße“
    static func phrase(landmark: Landmark, ordinal: Int, direction: String, road: String?) -> String? {
        let ordinals = ["nächsten", "zweiten", "dritten"]
        guard (1...3).contains(ordinal) else { return nil }
        let place: String
        switch landmark {
        case .trafficLight: place = "An der \(ordinals[ordinal - 1]) Ampel"
        case .stopSign: place = "Am \(ordinals[ordinal - 1]) Stoppschild"
        }
        return "\(place) \(direction) abbiegen" + (road.map { " auf \($0)" } ?? "")
    }

    static func directionText(_ direction: ManeuverDirection?) -> String? {
        switch direction {
        case .left: "links"
        case .right: "rechts"
        case .slightLeft: "leicht links"
        case .slightRight: "leicht rechts"
        case .sharpLeft: "scharf links"
        case .sharpRight: "scharf rechts"
        default: nil
        }
    }
}
