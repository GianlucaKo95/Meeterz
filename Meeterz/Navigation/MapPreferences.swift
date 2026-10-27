import Foundation

/// Eine Kartenansicht für iPhone und CarPlay: Kartenart (Satellit / Klassisch / Flyover) und 2D/3D.
/// Egal wo man umschaltet – iPhone-Karte, Einstellungen oder CarPlay „Kartenansicht“ –, es gilt überall sofort.
/// Gespeichert wird in den bisherigen Schlüsseln beider Seiten, damit alle Stellen, die sie lesen, mitziehen.
@MainActor
enum MapPreferences {
    enum Style: String, CaseIterable, Identifiable {
        case satellite, classic, flyover
        var id: String { rawValue }
        var title: String {
            switch self {
            case .satellite: String(localized: "Satellit")
            case .classic: String(localized: "Klassisch")
            case .flyover: String(localized: "Apple Flyover (experimentell)")
            }
        }
    }

    static var style: Style {
        Style(rawValue: UserDefaults.standard.string(forKey: "map.style") ?? "") ?? .satellite
    }

    static var threeD: Bool { UserDefaults.standard.object(forKey: "map.3d") as? Bool ?? true }

    static func setStyle(_ style: Style) {
        let d = UserDefaults.standard
        d.set(style.rawValue, forKey: "map.style")
        d.set(style != .classic, forKey: "map.satellite")          // iPhone-Navigation: Luftbild oder Karte
        d.set(style == .flyover, forKey: "carplay.flyover")
        if style != .flyover { d.set(style == .satellite, forKey: "carplay.satellite") }
        // Gilt sofort überall: CarPlay (freie Fahrt und Navigation, Dashboard) und iPhone-Navigation.
        // Die iPhone-Karte außerhalb der Navigation liest „map.style“ direkt (@AppStorage).
        CarPlayController.shared.applyMapStyle()
        AppModel.shared.navigation.applyMapStyle()
    }

    static func setThreeD(_ on: Bool) {
        let d = UserDefaults.standard
        d.set(on, forKey: "map.3d")
        d.set(on, forKey: "carplay.3d")
        CarPlayController.shared.applyThreeD()
    }

    /// Einmalig: bisher getrennte Einstellungen zusammenführen. CarPlay war bewusst eingestellt, das iPhone hatte
    /// noch die alte Bedeutung („Satellit“ = Flyover) – darum gilt der CarPlay-Stand.
    static func migrate() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "map.unified") else { return }
        d.set(true, forKey: "map.unified")
        _ = CarPlayFlyoverMirror.isEnabled   // ältere Umstellung auf Satellit zuerst
        let flyover = d.object(forKey: "carplay.flyover") as? Bool ?? false
        let satellite = d.object(forKey: "carplay.satellite") as? Bool ?? true
        let style: Style = flyover ? .flyover : (satellite ? .satellite : .classic)
        let three = d.object(forKey: "carplay.3d") as? Bool ?? true
        d.set(style.rawValue, forKey: "map.style")
        d.set(style != .classic, forKey: "map.satellite")
        d.set(three, forKey: "map.3d")
    }
}
