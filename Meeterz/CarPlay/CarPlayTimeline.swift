import UIKit
import SwiftUI
import CoreLocation
import MapboxNavigationUIKit

/// Zeitleiste „Wer ist wann da“ in CarPlay: kleine Einblendung unten links auf der Navigationskarte, nur solange noch
/// jemand zum selben Ziel fährt (oder schon dort ist). Damit sie nie die Route überdeckt, rückt die Kamera den
/// Fahrzeugpunkt um ihre Höhe nach oben – die Route vor einem liegt dann immer darüber. Zu wenig Platz: keine Einblendung.
@MainActor
final class CarPlayTimeline {
    static let shared = CarPlayTimeline()
    private var host: UIHostingController<AnyView>?
    private var timer: Timer?
    private var paddingBefore: UIEdgeInsets?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in CarPlayTimeline.shared.update() }
        }
        update()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        hide()
    }

    func update() {
        let app = AppModel.shared
        let nav = app.navigation
        guard CarPlayController.shared.isConnected, nav.isNavigating, let dest = nav.destination,
              let view = CarPlayController.shared.manager.carPlayNavigationViewController?.view else { return hide() }
        var items: [ArrivalTimeline.Item] = []
        for item in app.friendsOnMap where !Passengers.shared.riding.contains(item.friend.friendId) {
            let id = item.friend.friendId
            let here = item.position.coordinate.distance(to: dest.coordinate) < 150
            let route = app.routes.route(of: id, to: dest.coordinate)
            guard here || route != nil else { continue }
            items.append(.init(id: id.uuidString, name: item.friend.firstName, color: FriendPalette.routeColor(for: id), eta: route?.eta, here: here))
        }
        guard !items.isEmpty else { return hide() }
        items.append(.init(id: "me", name: String(localized: "Du"), color: Color(uiColor: Theme.mintUI), eta: nav.eta, here: false))

        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let size = CGSize(width: min(340, safe.width * 0.5), height: 104)
        // Kleine Anzeige: lieber keine Zeitleiste, als die Route zu verdrängen
        guard size.height < safe.height * 0.35 else { return hide() }
        let content = AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Text(dest.name).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 1, opacity: 0.7)).lineLimit(1)
                ArrivalTimeline(items: items)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.067, green: 0.09, blue: 0.098).opacity(0.94)))
            .environment(\.colorScheme, .dark)
        )
        let h = host ?? UIHostingController(rootView: content)
        h.rootView = content
        if h.view.superview !== view {
            h.view.removeFromSuperview()
            h.view.backgroundColor = .clear
            h.view.isUserInteractionEnabled = false
            view.addSubview(h.view)
        }
        h.view.frame = CGRect(x: safe.minX + 10, y: safe.maxY - size.height - 10, width: size.width, height: size.height)
        host = h
        // Fahrzeugpunkt über die Einblendung schieben
        if let map = CarPlayController.shared.manager.carPlayNavigationViewController?.navigationMapView {
            if paddingBefore == nil { paddingBefore = map.viewportPadding }
            var padding = paddingBefore ?? map.viewportPadding
            padding.bottom += size.height + 10
            if map.viewportPadding != padding { map.viewportPadding = padding }
        }
    }

    private func hide() {
        host?.view.removeFromSuperview()
        host = nil
        if let before = paddingBefore, let map = CarPlayController.shared.manager.carPlayNavigationViewController?.navigationMapView {
            map.viewportPadding = before
        }
        paddingBefore = nil
    }
}
