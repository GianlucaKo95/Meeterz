import SwiftUI
import UIKit

/// Meeterz-Look nach dem Logo: Petrol-Grund, Mint-Akzent, Bernstein, runde Schrift (dunkel bzw. hell).
/// Alle Farben passen sich dem Erscheinungsbild an (Einstellung „Darstellung“: System, Hell, Dunkel).
enum Theme {
    enum UI {
        // Farben aus dem Logo: tiefes Petrol (Grund), Mint (Akzent), Bernstein (zweite Markenfarbe)
        static let ink = dynamic(dark: 0x062A32, light: 0xEEF4F4)
        static let panel = dynamic(dark: 0x0A3640, light: 0xFFFFFF)
        static let panelRaised = dynamic(dark: 0x0F414C, light: 0xE3ECED)
        static let stroke = dynamic(dark: 0x134A54, light: 0xCBD8DA)
        static let text = dynamic(dark: 0xEEF8F7, light: 0x082B33)
        static let muted = dynamic(dark: 0x8FB3B4, light: 0x4E6A70)
        /// Hell: dunkleres Türkis, damit Text und Symbole auf Weiß lesbar bleiben
        static let accent = dynamic(dark: 0x6FF3DA, light: 0x0B7F70)
        static let danger = dynamic(dark: 0xFF5A5F, light: 0xD92D35)
        /// Bernstein: „ist unterwegs“ / „ist da“ – bewusst nicht Mint, damit es sich vom Akzent abhebt
        static let go = dynamic(dark: 0xFFC857, light: 0xA86B00)
        static let amber = go
    }

    static let ink = Color(uiColor: UI.ink)
    static let panel = Color(uiColor: UI.panel)
    static let panelRaised = Color(uiColor: UI.panelRaised)
    static let stroke = Color(uiColor: UI.stroke)
    static let text = Color(uiColor: UI.text)
    static let muted = Color(uiColor: UI.muted)
    static let accent = Color(uiColor: UI.accent)
    static let danger = Color(uiColor: UI.danger)
    /// „ist unterwegs“ / „ist da“ in Bernstein (bewusst nicht Mint wie der Akzent)
    static let go = Color(uiColor: UI.go)

    static let accentUI = UI.accent
    /// Feste Markenfarben für Karte und CarPlay (dort gibt es kein App-Erscheinungsbild)
    static let mintUI = UIColor(hex: 0x6FF3DA)
    static let petrolUI = UIColor(hex: 0x062A32)

    static func dynamic(dark: UInt32, light: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .light ? UIColor(hex: light, alpha: alpha) : UIColor(hex: dark, alpha: alpha) }
    }

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func title(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Darstellung der App auf dem iPhone (CarPlay hat sein eigenes Erscheinungsbild)
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Wie System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }
    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    static let key = "app.appearance"
    /// Standard bleibt der bisherige dunkle Look
    static var current: AppAppearance {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .dark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); apply() }
    }

    /// Setzt das Erscheinungsbild für alle iPhone-Fenster – auch für die UIKit-Navigation von Mapbox
    @MainActor static func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = current.style }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension FriendPalette {
    static func color(for id: UUID) -> Color { Color(uiColor: uiColor(for: id)) }
    static func routeColor(for id: UUID) -> Color { Color(uiColor: routeUIColor(for: id)) }
}

// MARK: Bausteine

/// Profilbild des Nutzers (`userId`), sonst Initialen auf Farbe
struct Avatar: View {
    @Environment(AppModel.self) private var app
    let initials: String
    let color: Color
    var size: CGFloat = 40
    var faded = false
    var userId: UUID?

    var body: some View {
        Group {
            if let userId, let photo = app.avatars.image(for: userId) {
                Image(uiImage: photo)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .opacity(faded ? 0.5 : 1)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .frame(width: size, height: size)
                    .background(Circle().fill(color.opacity(faded ? 0.5 : 1)))
            }
        }
        .overlay(Circle().stroke(Theme.ink, lineWidth: 3))
        .accessibilityHidden(true)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Capsule().stroke(Theme.stroke, lineWidth: 1).background(Capsule().fill(configuration.isPressed ? Theme.panelRaised : .clear)))
    }
}

struct CircleIconButton: View {
    let systemName: String
    let label: String
    var tint: Color = Theme.text
    var badge = false
    /// Bernsteinfarbener Punkt: z. B. ein Freund ist gerade per Navigation unterwegs
    var activeDot = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Theme.panel))
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                .overlay(alignment: badge ? .bottomTrailing : .topTrailing) {
                    if activeDot {
                        Circle().fill(Theme.go).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                            .offset(x: -6, y: badge ? -6 : 6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle().fill(Theme.danger).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                            .offset(x: -6, y: 6)
                    }
                }
        }
        .accessibilityLabel(label)
        .accessibilityValue(activeDot ? "Ein Freund ist unterwegs" : "")
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.stroke, lineWidth: 1))
    }
}

enum Format {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func minutes(seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        return m < 60 ? "\(m) Min" : "\(m / 60) Std \(m % 60) Min"
    }

    static func minutes(until date: Date) -> String {
        let m = max(0, Int(date.timeIntervalSinceNow / 60))
        return m < 60 ? "\(m) Min" : "\(m / 60) Std \(m % 60) Min"
    }

    static func distance(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func age(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "live" }
        if seconds < 3600 { return "vor \(Int(seconds / 60)) Min." }
        return "vor \(Int(seconds / 3600)) Std."
    }
}
