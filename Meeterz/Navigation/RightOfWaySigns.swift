import UIKit
import CoreLocation
import MapboxDirections
import MapboxNavigationCore

/// „Vorfahrt achten“ und „Stopp“ unter dem Tempolimit einblenden, kurz bevor man das Schild erreicht – als Erinnerung,
/// ohne Ansage. Die Angaben kommen von Mapbox (Kreuzungen der Route), darum nur während einer Routenführung.
/// Das Schild sitzt direkt unter dem Tempolimit am Rand, nicht über der Route.
@MainActor
final class RightOfWaySigns {
    static let shared = RightOfWaySigns()

    enum Sign: Equatable { case yield, stop }

    /// So weit voraus wird das Schild gezeigt (Luftlinie zum markierten Knoten)
    static let showWithin: CLLocationDistance = 150

    private var signViews: [ObjectIdentifier: UIImageView] = [:]
    private var lastLogged: Sign?

    /// Schild neben diesen Tempolimit-Anzeigen zeigen oder ausblenden (jede Sekunde aufrufen)
    func update(below speedLimitViews: [UIView]) {
        let sign = AppModel.shared.navigation.isNavigating ? Self.upcoming() : nil
        if sign?.0 != lastLogged {
            lastLogged = sign?.0
            if let sign { Diag.log("Schild eingeblendet: \(sign.0 == .stop ? "Stopp" : "Vorfahrt achten") in \(Int(sign.1)) m") }
        }
        for anchor in speedLimitViews {
            let key = ObjectIdentifier(anchor)
            // CarPlay: das Tempolimit steckt in einem eigenen Rahmen – darunter ausrichten
            let frame = anchor.superview?.superview != nil && anchor.superview?.bounds.size == anchor.bounds.size ? anchor.superview! : anchor
            guard let host = frame.superview else { continue }
            let view: UIImageView
            if let existing = signViews[key], existing.superview === host {
                view = existing
            } else {
                signViews[key]?.removeFromSuperview()
                view = UIImageView()
                view.translatesAutoresizingMaskIntoConstraints = false
                view.contentMode = .scaleAspectFit
                view.isUserInteractionEnabled = false
                host.addSubview(view)
                let size = max(frame.bounds.width, 44)
                NSLayoutConstraint.activate([
                    view.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: 6),
                    view.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
                    view.widthAnchor.constraint(equalToConstant: size),
                    view.heightAnchor.constraint(equalToConstant: size),
                ])
                signViews[key] = view
            }
            if let sign {
                let image = Self.image(sign.0)
                if view.image !== image { view.image = image }
                view.isHidden = false
            } else {
                view.isHidden = true
            }
        }
        // Verschwundene Anzeigen (z. B. Navigation beendet) vergessen
        let alive = Set(speedLimitViews.map(ObjectIdentifier.init))
        for (key, view) in signViews where !alive.contains(key) && view.window == nil {
            view.removeFromSuperview()
            signViews[key] = nil
        }
    }

    func hideAll() {
        for view in signViews.values { view.isHidden = true }
    }

    // MARK: Daten

    /// Nächstes Vorfahrt- oder Stoppschild auf der Route voraus, höchstens `showWithin` entfernt
    static func upcoming() -> (Sign, CLLocationDistance)? {
        guard let progress = navigationProvider.mapboxNavigation.navigation().currentRouteProgress?.routeProgress,
              let here = AppModel.shared.location.lastLocation else { return nil }
        let leg = progress.currentLegProgress
        let step = leg.currentStepProgress
        let all = step.intersectionsIncludingUpcomingManeuverIntersection ?? (leg.currentStep.intersections ?? [])
        var ahead = Array(all.dropFirst(min(step.intersectionIndex + 1, all.count)))
        if let next = leg.upcomingStep?.intersections { ahead += next.dropFirst() }
        for x in ahead {
            let d = here.distance(from: CLLocation(latitude: x.location.latitude, longitude: x.location.longitude))
            if d > 2 * showWithin { break }        // weiter vorn kommt nichts Relevantes mehr
            guard d <= showWithin else { continue }
            if x.stopSign == true { return (.stop, d) }
            if x.yieldSign == true { return (.yield, d) }
        }
        return nil
    }

    // MARK: Schilder (selbst gezeichnet, wie die deutschen Verkehrszeichen 205 und 206)

    private static var cache: [Sign: UIImage] = [:]

    static func image(_ sign: Sign) -> UIImage {
        if let cached = cache[sign] { return cached }
        let size = CGSize(width: 96, height: 96)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let red = UIColor(red: 0.80, green: 0.08, blue: 0.10, alpha: 1)
            switch sign {
            case .yield:
                // Auf der Spitze stehendes Dreieck, weiß mit rotem Rand
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 4, y: 10))
                path.addLine(to: CGPoint(x: 92, y: 10))
                path.addLine(to: CGPoint(x: 48, y: 90))
                path.close()
                path.lineJoinStyle = .round
                red.setFill(); path.fill()
                let inner = UIBezierPath()
                inner.move(to: CGPoint(x: 22, y: 20))
                inner.addLine(to: CGPoint(x: 74, y: 20))
                inner.addLine(to: CGPoint(x: 48, y: 68))
                inner.close()
                UIColor.white.setFill(); inner.fill()
            case .stop:
                // Rotes Achteck mit weißem Rand und „STOP“
                let path = UIBezierPath()
                for i in 0..<8 {
                    let angle = CGFloat(i) * .pi / 4 + .pi / 8
                    let p = CGPoint(x: 48 + 45 * cos(angle), y: 48 + 45 * sin(angle))
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                path.close()
                UIColor.white.setFill(); path.fill()
                c.saveGState()
                c.translateBy(x: 48, y: 48); c.scaleBy(x: 0.88, y: 0.88); c.translateBy(x: -48, y: -48)
                red.setFill(); path.fill()
                c.restoreGState()
                let text = "STOP" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 25, weight: .heavy), .foregroundColor: UIColor.white]
                let ts = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: 48 - ts.width / 2, y: 48 - ts.height / 2), withAttributes: attrs)
            }
        }
        cache[sign] = image
        return image
    }
}
