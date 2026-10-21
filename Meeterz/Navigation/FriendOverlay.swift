import Foundation
import UIKit
import MapboxMaps

/// Freunde, ihre Routen und vereinbarte Treffpunkte auf einer UIKit-Karte
/// (Navigationsansicht auf dem iPhone und auf CarPlay).
@MainActor
final class FriendOverlay {
    private let markers: PointAnnotationManager
    private let lines: PolylineAnnotationManager
    private let isVisible: () -> Bool
    private var timer: Timer?

    init(mapView: MapView, isVisible: @escaping () -> Bool) {
        let suffix = UUID().uuidString.prefix(6)
        lines = mapView.annotations.makePolylineAnnotationManager(id: "meeterz-routes-\(suffix)")
        markers = mapView.annotations.makePointAnnotationManager(id: "meeterz-friends-\(suffix)")
        self.isVisible = isVisible
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        markers.annotations = []
        lines.annotations = []
    }

    func refresh() {
        guard isVisible() else {
            markers.annotations = []
            lines.annotations = []
            return
        }
        let model = AppModel.shared

        var lineItems: [PolylineAnnotation] = model.routes.friendRoutes.values.map { route in
            var casing = PolylineAnnotation(id: "routecase-\(route.friendId)", lineCoordinates: route.coordinates)
            casing.lineColor = StyleColor(FriendPalette.routeCasing)
            casing.lineWidth = 10
            return casing
        }
        lineItems += model.routes.friendRoutes.values.map { route in
            var line = PolylineAnnotation(id: "route-\(route.friendId)", lineCoordinates: route.coordinates)
            line.lineColor = StyleColor(FriendPalette.routeUIColor(for: route.friendId))
            line.lineWidth = 6
            return line
        }
        lines.annotations = lineItems

        var points: [PointAnnotation] = model.friendsOnMap.map { item in
            var p = PointAnnotation(id: "friend-\(item.friend.friendId)", coordinate: item.position.coordinate)
            let stale = item.position.age > 5 * 60
            let photo = model.avatars.image(for: item.friend.friendId)
            p.image = .init(
                image: AvatarRenderer.image(initials: item.friend.initials,
                                            color: FriendPalette.uiColor(for: item.friend.friendId),
                                            faded: stale,
                                            photo: photo),
                name: "avatar-\(item.friend.friendId)-\(stale)-\(item.friend.avatarVersion ?? 0)-\(photo != nil)"
            )
            p.textField = item.friend.displayName
            p.textOffset = [0, 2.2]
            p.textSize = 13
            p.textColor = StyleColor(.white)
            p.textHaloColor = StyleColor(.black)
            p.textHaloWidth = 1.5
            return p
        }

        points += model.meetups.accepted.map { meetup in
            var p = PointAnnotation(id: "meetup-\(meetup.id)", coordinate: meetup.coordinate)
            p.image = .init(image: AvatarRenderer.meetupPin(), name: "meetup-pin")
            p.textField = meetup.placeName
            p.textOffset = [0, 2.4]
            p.textSize = 13
            p.textColor = StyleColor(Theme.accentUI)
            p.textHaloColor = StyleColor(.black)
            p.textHaloWidth = 1.5
            return p
        }
        markers.annotations = points
    }
}

/// Feste Farbe je Freund (stabil über App-Starts)
enum FriendPalette {
    static let colors: [UIColor] = [
        UIColor(red: 1.00, green: 0.54, blue: 0.24, alpha: 1),  // Orange
        UIColor(red: 0.72, green: 0.58, blue: 0.96, alpha: 1),  // Violett
        UIColor(red: 0.30, green: 0.89, blue: 0.77, alpha: 1),  // Türkis
        UIColor(red: 0.30, green: 0.64, blue: 1.00, alpha: 1),  // Blau
        UIColor(red: 1.00, green: 0.42, blue: 0.62, alpha: 1),  // Pink
        UIColor(red: 1.00, green: 0.76, blue: 0.24, alpha: 1),  // Gelb
    ]

    static func uiColor(for id: UUID) -> UIColor {
        colors[Int(id.uuid.0) % colors.count]
    }

    /// Knallige Routenfarben, die sich auf dunkler und heller Karte absetzen (Reihenfolge wie `colors`)
    static let routeColors: [UIColor] = [
        UIColor(red: 1.00, green: 0.43, blue: 0.00, alpha: 1),  // Neon-Orange
        UIColor(red: 0.85, green: 0.20, blue: 1.00, alpha: 1),  // Magenta-Violett
        UIColor(red: 0.00, green: 0.90, blue: 1.00, alpha: 1),  // Cyan
        UIColor(red: 0.15, green: 0.45, blue: 1.00, alpha: 1),  // Elektrisch-Blau
        UIColor(red: 1.00, green: 0.10, blue: 0.55, alpha: 1),  // Neon-Pink
        UIColor(red: 1.00, green: 0.93, blue: 0.00, alpha: 1),  // Leuchtgelb
    ]

    static func routeUIColor(for id: UUID) -> UIColor {
        routeColors[Int(id.uuid.0) % routeColors.count]
    }

    /// Dunkle Umrandung unter der Route, damit sie auch auf Satellitenbild und hellen Flächen lesbar bleibt
    static let routeCasing = UIColor(red: 0.02, green: 0.04, blue: 0.07, alpha: 0.92)
}

enum AvatarRenderer {
    static func image(initials: String, color: UIColor, faded: Bool, photo: UIImage? = nil) -> UIImage {
        let size = CGSize(width: 44, height: 44)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: rect)
            if let photo {
                // Foto im Kreis, farbiger Rand wie beim Initialen-Marker
                let inner = rect.insetBy(dx: 3, dy: 3)
                color.withAlphaComponent(faded ? 0.5 : 1).setFill()
                ctx.cgContext.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
                ctx.cgContext.saveGState()
                ctx.cgContext.addEllipse(in: inner)
                ctx.cgContext.clip()
                photo.draw(in: inner, blendMode: .normal, alpha: faded ? 0.5 : 1)
                ctx.cgContext.restoreGState()
                return
            }
            color.withAlphaComponent(faded ? 0.5 : 1).setFill()
            ctx.cgContext.fillEllipse(in: rect.insetBy(dx: 3, dy: 3))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15, weight: .heavy),
                .foregroundColor: UIColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1),
            ]
            let text = initials as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                      withAttributes: attrs)
        }
    }

    static func meetupPin() -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)
        let symbol = UIImage(systemName: "mappin.circle.fill", withConfiguration: config)?
            .withTintColor(Theme.accentUI, renderingMode: .alwaysOriginal)
        return symbol ?? UIImage()
    }
}
