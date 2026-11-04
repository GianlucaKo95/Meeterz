import Foundation
import ActivityKit

/// Live-Aktivität während der Navigation (Sperrbildschirm und Dynamic Island).
/// Wird von App und Widget-Erweiterung gemeinsam benutzt.
struct NavigationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// SF-Symbol der nächsten Abbiegung
        var symbol: String
        /// Straße bzw. Hinweis der nächsten Abbiegung
        var instruction: String
        /// Meter bis zur Abbiegung
        var distanceToTurn: Double
        var arrival: Date
        /// Meter bis zum Ziel
        var remainingDistance: Double
        /// Freund, der zum selben Ziel fährt (optional)
        var friendName: String?
        var friendInitials: String?
        var friendArrival: Date?
        var friendHere: Bool
        /// Live-Daten des Autos (nur mit verbundenem Auto). Die kleine Ansicht (CarPlay-Dashboard) zeigt sie statt
        /// der Abbiegung – die steht dort schon in Meeterz' eigener Karte daneben.
        var soc: Double? = nil
        var rangeKm: Double? = nil
        var arrivalSoc: Double? = nil
        /// Verbrauch dieser Fahrt in kWh/100 km
        var consumption: Double? = nil
    }

    var destinationName: String
}

/// Kleine Formatierer, die App und Erweiterung gleich benutzen
enum ActivityFormat {
    static func distance(_ meters: Double) -> String {
        if meters < 1000 {
            let rounded = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
            return String(localized: "\(Int(max(rounded, 0))) m")
        }
        return (meters / 1000).formatted(.number.precision(.fractionLength(1))) + " km"
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
