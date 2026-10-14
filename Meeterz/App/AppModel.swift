import Foundation
import CoreLocation
import Observation

/// Zentrale Klammer um alle Stores. iPhone-UI und CarPlay greifen auf dieselbe Instanz zu.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let auth = AuthStore()
    let location = LocationService()
    let friends = FriendsStore()
    let hub = LiveLocationHub()
    let routes = RoutesStore()
    let meetups = MeetupsStore()
    let navigation = NavigationCoordinator()
    let push = PushService()
    let avatars = AvatarStore()

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }
    private(set) var banner: Banner?

    @ObservationIgnored private var sessionUser: UUID?
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    var profile: Profile? { auth.profile }

    // MARK: Sitzung

    /// Startet alles, was nach dem Login laufen soll. Mehrfacher Aufruf ist harmlos.
    func startSession() async {
        guard let profile, sessionUser != profile.id else { return }
        sessionUser = profile.id

        location.onUpdate = { [weak self] loc in
            Task { await self?.onLocation(loc) }
        }
        location.requestPermission()

        await hub.startPublishing(userId: profile.id)
        await meetups.startListening(userId: profile.id)
        await push.registerIfPossible()

        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSocial()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func endSession() async {
        avatars.reset()
        refreshLoop?.cancel()
        refreshLoop = nil
        sessionUser = nil
        location.onUpdate = nil
        navigation.stop()
        await hub.stopAll()
        await meetups.stopListening()
    }

    /// Freunde, Routen, Treffen und Treffpunkte neu laden
    func refreshSocial() async {
        guard sessionUser != nil else { return }
        await friends.refresh()
        await avatars.sync(friends: friends.rows, me: auth.profile)
        await hub.sync(with: friends.rows)
        await routes.refresh()
        await meetups.refresh()
    }

    private func onLocation(_ loc: CLLocation) async {
        guard let profile else { return }
        await hub.publish(loc, userId: profile.id, sharingEnabled: profile.isSharingNow)
    }

    func signOut() async {
        await endSession()
        await auth.signOut()
    }

    func deleteAccount() async {
        if let id = auth.profile?.id { await avatars.deleteFile(userId: id) }
        await endSession()
        await auth.deleteAccount()
    }

    // MARK: Hinweise

    func show(_ text: String, isError: Bool = true) {
        let b = Banner(text: text, isError: isError)
        banner = b
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.banner == b { self?.banner = nil }
        }
    }

    func dismissBanner() { banner = nil }

    // MARK: Abgeleitete Daten für Karten (iPhone + CarPlay)

    struct FriendOnMap: Identifiable {
        let friend: FriendRow
        let position: LivePosition
        var id: UUID { friend.friendId }
    }

    var friendsOnMap: [FriendOnMap] {
        friends.accepted.compactMap { f in
            hub.positions[f.friendId].map { FriendOnMap(friend: f, position: $0) }
        }
    }

    func friend(_ id: UUID) -> FriendRow? {
        friends.rows.first { $0.friendId == id }
    }
}
