import UIKit

/// Infofenster zum Routenvorschlag (wie Apple Karten): wohin, warum und wann man ankommt.
/// Im Dashboard und Kombiinstrument über der Routenvorschau, in der großen Karte rechts neben CarPlays Auswahlkarte.
///
///   📅 Zahnarzt Dr. Weber              (Termin bzw. Ort)
///      Königstraße 12, Duisburg        (Ziel – beim Termin der Ort)
///      Termin 09:00 · 24 Min. · an 08:41
final class SuggestionCardView: UIView {
    private let icon = UIImageView()
    private let title = UILabel()
    private let destination = UILabel()
    private let detail = UILabel()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 0.024, green: 0.165, blue: 0.196, alpha: 0.92)
        layer.cornerRadius = 14
        layer.borderColor = Theme.mintUI.withAlphaComponent(0.6).cgColor
        layer.borderWidth = 1
        icon.tintColor = Theme.mintUI
        icon.contentMode = .scaleAspectFit
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = .white
        destination.font = .systemFont(ofSize: 13, weight: .regular)
        destination.textColor = UIColor(white: 1, alpha: 0.85)
        detail.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.textColor = Theme.mintUI
        for v in [icon, title, destination, detail] { addSubview(v) }
    }

    required init?(coder: NSCoder) { nil }

    func show(_ s: RouteSuggestions.Suggestion) {
        let calendar: Bool
        if case .calendar = s.reason { calendar = true } else { calendar = false }
        icon.image = UIImage(systemName: calendar ? "calendar" : "clock.arrow.circlepath")
        title.text = s.title
        destination.text = s.destinationText
        destination.isHidden = s.destinationText.isEmpty
        detail.text = s.detailText
        setNeedsLayout()
    }

    /// Breite vorgeben, Höhe ergibt sich aus den Zeilen
    func fit(width: CGFloat) -> CGSize {
        let lines = destination.isHidden ? 2 : 3
        return CGSize(width: width, height: CGFloat(lines) * 19 + 18)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x: CGFloat = 40, w = bounds.width - x - 10
        icon.frame = CGRect(x: 10, y: 10, width: 22, height: 22)
        var y: CGFloat = 9
        title.frame = CGRect(x: x, y: y, width: w, height: 20); y += 19
        if !destination.isHidden { destination.frame = CGRect(x: x, y: y, width: w, height: 19); y += 19 }
        detail.frame = CGRect(x: x, y: y, width: w, height: 19)
    }

    /// Fenster in `host` anzeigen bzw. aktualisieren (nil = entfernen). `rightAligned`: rechts oben statt links oben.
    static func place(_ card: inout SuggestionCardView?, suggestion: RouteSuggestions.Suggestion?, in host: UIView?, rightAligned: Bool) {
        guard let suggestion, let host else { card?.removeFromSuperview(); card = nil; return }
        let view = card ?? SuggestionCardView()
        if view.superview !== host { view.removeFromSuperview(); host.addSubview(view) }
        view.show(suggestion)
        let safe = host.bounds.inset(by: host.safeAreaInsets)
        let width = min(300, max(180, safe.width - 20))
        let size = view.fit(width: width)
        view.frame = CGRect(x: rightAligned ? safe.maxX - size.width - 10 : safe.minX + 10, y: safe.minY + 10,
                            width: size.width, height: size.height)
        card = view
    }
}
