import Foundation
import ActivityKit

/// Live-Aktivität für ein Treffen: wo die Verabredeten gerade sind („Annika · 4 Min.“, „Niklas · da“).
/// Wird von App und Widget-Erweiterung gemeinsam benutzt.
struct MeetupActivityAttributes: ActivityAttributes {
    struct Member: Codable, Hashable {
        var name: String
        var initials: String
        /// Meter bis zum Treffpunkt (nil = kein Standort)
        var distance: Double?
        /// Ankunft laut geteilter Route
        var eta: Date?
        var here: Bool
    }

    struct ContentState: Codable, Hashable {
        var members: [Member]
    }

    var placeName: String
    var meetAt: Date?
}
