import Foundation
import WidgetKit
import CoreLocation

/// Schreibt den Datenstand für die Widgets und stößt deren Aktualisierung an –
/// sparsam, weil iOS Widget-Aktualisierungen pro Tag begrenzt.
@MainActor
final class WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()

    private var lastWrite = Date.distantPast
    private var lastReload = Date.distantPast
    private var lastSaved: WidgetSnapshot?

    /// `force`: sofort neu laden (z. B. Treffen angenommen, Teilen umgeschaltet)
    func update(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastWrite) > 30 else { return }
        lastWrite = Date()
        let snapshot = makeSnapshot()
        WidgetSnapshotStore.save(snapshot)

        let important = snapshot.meetup != lastSaved?.meetup
            || snapshot.sharing != lastSaved?.sharing
            || snapshot.incognito != lastSaved?.incognito
            || snapshot.friends.map(\.name) != lastSaved?.friends.map(\.name)
        lastSaved = snapshot
        if force || important || Date().timeIntervalSince(lastReload) > 15 * 60 {
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func clear() {
        lastSaved = nil
        WidgetSnapshotStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func makeSnapshot() -> WidgetSnapshot {
        let app = AppModel.shared
        let me = app.location.lastLocation?.coordinate

        let friends: [WidgetSnapshot.Friend] = app.friendsOnMap.map { item in
            let route = app.routes.friendRoutes[item.friend.friendId]
            return WidgetSnapshot.Friend(
                name: item.friend.displayName.split(separator: " ").first.map(String.init) ?? item.friend.displayName,
                initials: item.friend.initials,
                distance: me.map { item.position.coordinate.distance(to: $0) },
                heading: route.map { r in r.destinationName.map { "nach \($0)" } ?? "unterwegs" },
                arrival: route?.eta,
                seen: Date().addingTimeInterval(-item.position.age))
        }
        .sorted { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }

        var meetup: WidgetSnapshot.Meetup?
        if let m = app.meetups.accepted.first {
            let friendEta = app.routes.friendRoutes[m.otherId]
                .flatMap { $0.destination.distance(to: m.coordinate) < 300 ? $0.eta : nil }
            let myEta = app.navigation.destination
                .flatMap { $0.coordinate.distance(to: m.coordinate) < 300 ? app.navigation.eta : nil }
            meetup = WidgetSnapshot.Meetup(place: m.placeName,
                                           with: m.otherName.split(separator: " ").first.map(String.init) ?? m.otherName,
                                           friendArrival: friendEta, myArrival: myEta)
        }

        let profile = app.profile
        return WidgetSnapshot(updated: Date(),
                              sharing: profile?.isSharingNow ?? false,
                              sharingUntil: profile?.sharingUntil,
                              incognito: profile?.isIncognito ?? false,
                              friends: Array(friends.prefix(6)),
                              meetup: meetup)
    }
}
