import Foundation
import MapboxDirections
import MapboxNavigationCore

/// Routenoptionen (nur Auto): Maut, Autobahnen, Fähren meiden.
/// Gilt für jede Routenberechnung – iPhone, CarPlay, Treffpunkte, Ladeplan-Übernahme – und für Neuberechnungen
/// unterwegs (Mapbox übernimmt die Optionen der laufenden Route).
enum RoutePreferences {
    enum Option: String, CaseIterable, Identifiable {
        case tolls, motorways, ferries
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tolls: "Maut meiden"
            case .motorways: "Autobahnen meiden"
            case .ferries: "Fähren meiden"
            }
        }
        var shortTitle: String {
            switch self {
            case .tolls: "ohne Maut"
            case .motorways: "ohne Autobahn"
            case .ferries: "ohne Fähre"
            }
        }
        var symbol: String {
            switch self {
            case .tolls: "eurosign.circle"
            case .motorways: "road.lanes"
            case .ferries: "ferry"
            }
        }
        fileprivate var roadClass: RoadClasses {
            switch self {
            case .tolls: .toll
            case .motorways: .motorway
            case .ferries: .ferry
            }
        }
        fileprivate var key: String { "route.avoid.\(rawValue)" }
    }

    static func isOn(_ option: Option) -> Bool { UserDefaults.standard.bool(forKey: option.key) }

    static func set(_ option: Option, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: option.key)
        Diag.log("Routenoption: \(option.title) \(on ? "an" : "aus")")
    }

    static var active: [Option] { Option.allCases.filter(isOn) }

    /// „ohne Maut, ohne Fähre“ – für Vorschau und CarPlay
    static var summary: String? {
        let a = active
        return a.isEmpty ? nil : a.map(\.shortTitle).joined(separator: ", ")
    }

    /// Auf Routenoptionen anwenden (nur Auto-Profile; zu Fuß/Rad gibt es keine Maut/Autobahn)
    static func apply(to options: NavigationRouteOptions) {
        guard options.profileIdentifier == .automobile || options.profileIdentifier == .automobileAvoidingTraffic else { return }
        options.roadClassesToAvoid = RoadClasses(active.map(\.roadClass))
    }
}
