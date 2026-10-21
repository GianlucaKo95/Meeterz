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
    }

    var destinationName: String
}

/// Kleine Formatierer, die App und Erweiterung gleich benutzen
enum ActivityFormat {
    static func distance(_ meters: Double) -> String {
        if meters < 1000 {
            let rounded = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
            return "\(Int(max(rounded, 0))) m"
        }
        return String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
