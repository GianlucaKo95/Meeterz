import Foundation
import MapboxDirections

/// Fortbewegungsart für Routen (auf CarPlay immer Auto).
enum TravelMode: String, CaseIterable, Identifiable, Codable {
    case car, bike, walk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .car: "Auto"
        case .bike: "Fahrrad"
        case .walk: "Zu Fuß"
        }
    }

    var icon: String {
        switch self {
        case .car: "car.fill"
        case .bike: "bicycle"
        case .walk: "figure.walk"
        }
    }

    var profile: ProfileIdentifier {
        switch self {
        case .car: .automobileAvoidingTraffic
        case .bike: .cycling
        case .walk: .walking
        }
    }

    /// „Max ist zu Fuß unterwegs“
    var activity: String {
        switch self {
        case .car: "mit dem Auto"
        case .bike: "mit dem Fahrrad"
        case .walk: "zu Fuß"
        }
    }

    private static let key = "nav.travelMode"

    static var saved: TravelMode {
        get { UserDefaults.standard.string(forKey: key).flatMap(TravelMode.init(rawValue:)) ?? .car }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Treffpunkt „auf der Route“ (z. B. Raststätte an der Autobahn) gibt es nur, wenn beide mit dem Auto fahren.
    static func canMeetOnRoute(_ a: TravelMode, _ b: TravelMode?) -> Bool {
        a == .car && (b ?? .car) == .car
    }
}

extension Locale {
    /// Sprache der Navigationsansagen: folgt der Systemsprache des iPhones (Rückfall Deutsch).
    static var navigation: Locale { Locale(identifier: Locale.preferredLanguages.first ?? "de_DE") }
}
