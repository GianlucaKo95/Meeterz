import Foundation
import UIKit
import CarPlay
import CoreLocation
import MapboxNavigationCore

/// Konvoi: Freunde, die zum selben Ziel fahren oder dort mit mir verabredet sind.
/// Abstand wird entlang meiner Route gemessen (nicht Luftlinie). Hinweise, wenn jemand anhält,
/// deutlich zurückfällt oder eine andere Strecke nimmt.
@MainActor
final class ConvoyTracker {
    static let shared = ConvoyTracker()

    struct Member {
        let friend: FriendRow
        /// Meter entlang meiner Route: positiv = vor mir, negativ = hinter mir; nil = nicht auf meiner Strecke
        let gap: Double?
        let arrival: Date?
        let stopped: Bool
        var firstName: String { friend.displayName.split(separator: " ").first.map(String.init) ?? friend.displayName }

        var summary: String {
            var parts: [String] = []
            if let gap {
                if abs(gap) < 150 { parts.append("direkt bei dir") }
                else { parts.append("\(Format.distance(abs(gap))) \(gap > 0 ? "vor" : "hinter") dir") }
            } else {
                parts.append("andere Strecke")
            }
            if stopped { parts.append("hält gerade") }
            if let arrival { parts.append("an \(Format.time.string(from: arrival))") }
            return parts.joined(separator: " · ")
        }
    }

    private struct State { var behindFar = false; var offRoute = false; var stoppedSince: Date?; var stopAnnounced = false }
    private var states: [UUID: State] = [:]

    // Route mit aufsummierten Metern (nur neu berechnen, wenn sich die Route ändert)
    private var routeKey = ""
    private var coords: [CLLocationCoordinate2D] = []
    private var cumulative: [Double] = []

    func reset() { states = [:] }

    /// Aktuelle Konvoi-Mitglieder (nur während einer Navigation)
    func members() -> [Member] {
        let app = AppModel.shared
        guard app.navigation.isNavigating, let destination = app.navigation.destination else { return [] }
        loadRoute()
        let me = app.location.lastLocation?.coordinate
        let myIndex = me.flatMap { nearest(to: $0)?.index }
        let meetupIds = Set(app.meetups.accepted.filter { $0.coordinate.distance(to: destination.coordinate) < 300 }.map(\.otherId))

        return app.friendsOnMap.compactMap { item in
            let id = item.friend.friendId
            let route = app.routes.friendRoutes[id]
            let sameDestination = route.map { $0.destination.distance(to: destination.coordinate) < 300 } ?? false
            guard sameDestination || meetupIds.contains(id) else { return nil }
            var gap: Double?
            if let myIndex, let hit = nearest(to: item.position.coordinate), hit.distance < 300 {
                gap = cumulative[hit.index] - cumulative[myIndex]
            }
            let stopped = item.position.age < 120 && (item.position.speed ?? 0) < 1
                && item.position.coordinate.distance(to: destination.coordinate) > 300
            return Member(friend: item.friend, gap: gap, arrival: route?.eta, stopped: stopped)
        }
        .sorted { ($0.gap ?? -.greatestFiniteMagnitude) > ($1.gap ?? -.greatestFiniteMagnitude) }
    }

    /// Alle 30 s aus CarPlay aufgerufen: Hinweise bei Veränderungen
    func check(notify: (String, FriendRow) -> Void) {
        let current = members()
        let ids = Set(current.map(\.friend.friendId))
        states = states.filter { ids.contains($0.key) }
        for m in current {
            var s = states[m.friend.friendId] ?? State()
            // Zurückgefallen: mehr als 3 km hinter mir (erst wieder melden, wenn er unter 1,5 km aufholt)
            if let gap = m.gap {
                if gap < -3_000, !s.behindFar { s.behindFar = true; notify("\(m.firstName) ist \(Format.distance(-gap)) hinter dir", m.friend) }
                if gap > -1_500 { s.behindFar = false }
            }
            // Andere Strecke
            if m.gap == nil, !s.offRoute { s.offRoute = true; notify("\(m.firstName) fährt eine andere Strecke", m.friend) }
            if m.gap != nil { s.offRoute = false }
            // Hält an (länger als 2 Minuten)
            if m.stopped {
                let since = s.stoppedSince ?? Date()
                s.stoppedSince = since
                if !s.stopAnnounced, Date().timeIntervalSince(since) > 120 {
                    s.stopAnnounced = true
                    notify("\(m.firstName) hält gerade an", m.friend)
                }
            } else {
                s.stoppedSince = nil
                s.stopAnnounced = false
            }
            states[m.friend.friendId] = s
        }
    }

    // MARK: Route

    private func loadRoute() {
        guard let shape = navigationProvider.mapboxNavigation.tripSession().currentNavigationRoutes?
                .mainRoute.route.shape?.coordinates, shape.count > 1 else { coords = []; cumulative = []; return }
        let key = "\(shape.count)-\(shape.first!.latitude)-\(shape.last!.longitude)"
        guard key != routeKey else { return }
        routeKey = key
        coords = shape
        var sum = 0.0
        cumulative = [0]
        for (a, b) in zip(shape, shape.dropFirst()) {
            sum += a.distance(to: b)
            cumulative.append(sum)
        }
    }

    private func nearest(to point: CLLocationCoordinate2D) -> (index: Int, distance: Double)? {
        guard !coords.isEmpty else { return nil }
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, c) in coords.enumerated() {
            let d = c.distance(to: point)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return (best, bestDistance)
    }
}

extension CarPlayController {
    /// Abschnitt „Konvoi“ für die „Mehr“-Liste während der Fahrt
    func convoySection() -> CPListSection? {
        let members = ConvoyTracker.shared.members()
        guard !members.isEmpty else { return nil }
        let items: [CPListItem] = members.prefix(6).map { m in
            let f = m.friend
            let image = AvatarRenderer.image(initials: f.initials, color: FriendPalette.uiColor(for: f.friendId),
                                             faded: false, photo: AppModel.shared.avatars.image(for: f.friendId))
            let item = CPListItem(text: m.firstName, detailText: m.summary, image: image)
            item.handler = { [weak self] _, done in
                self?.showQuickReplies(to: [f.friendId], meetupId: nil)
                done()
            }
            return item
        }
        return CPListSection(items: items, header: "Konvoi", sectionIndexTitle: nil)
    }
}
