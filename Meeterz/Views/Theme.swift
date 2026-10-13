import SwiftUI
import UIKit

/// Nachtfahrt-Look: dunkler Grund, ein Lime-Akzent, runde Schrift.
enum Theme {
    static let ink = Color(hex: 0x0E1116)
    static let panel = Color(hex: 0x161B22)
    static let panelRaised = Color(hex: 0x1D232C)
    static let stroke = Color(hex: 0x262F3C)
    static let text = Color(hex: 0xF2F4F7)
    static let muted = Color(hex: 0x9AA4B2)
    static let accent = Color(hex: 0xC6F432)
    static let danger = Color(hex: 0xFF5A5F)

    static let accentUI = UIColor(red: 0.78, green: 0.96, blue: 0.20, alpha: 1)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func title(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
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
}

// MARK: Bausteine

struct Avatar: View {
    let initials: String
    let color: Color
    var size: CGFloat = 40
    var faded = false

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(faded ? 0.5 : 1)))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Theme.panel))
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle().fill(Theme.danger).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                            .offset(x: -6, y: 6)
                    }
                }
        }
        .accessibilityLabel(label)
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
