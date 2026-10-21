import Foundation
import CoreLocation
import Observation
import UIKit

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
    let sounds = SoundStore()
    let favorites = FavoritesStore()
    let recents = RecentsStore()

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }
    private(set) var banner: Banner?

    /// Karte soll einen Freund (und optional seine restliche Route) zeigen, z. B. aus dem Unterwegs-Fenster
    struct MapFocus: Equatable {
        let token = UUID()
        let friendId: UUID
        let showRoute: Bool
    }
    var mapFocus: MapFocus?

    @ObservationIgnored private var sessionUser: UUID?
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    var profile: Profile? { auth.profile }

    // MARK: Sitzung

    /// Startet alles, was nach dem Login laufen soll. Mehrfacher Aufruf ist harmlos.
    func startSession() async {
        guard let profile, sessionUser != profile.id else { return }
        sessionUser = profile.id
        favorites.load(userId: profile.id)
        recents.load(userId: profile.id)

        location.onUpdate = { [weak self] loc in
            Task { await self?.onLocation(loc) }
        }
        location.isSharing = { [weak self] in self?.profile?.isSharingNow ?? true }
        location.mayResumeSharing = { [weak self] in
            guard let p = self?.profile else { return false }
            return p.isIncognito && !p.isIncognitoIndefinitely
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
        sounds.reset()
        favorites.reset()
        recents.reset()
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
        await sounds.sync()
        await hub.sync(with: friends.rows)
        await routes.refresh()
        await meetups.refresh()
        requestFreshPositions()
    }

    // MARK: Standort auf Anfrage (stiller Push)

    @ObservationIgnored private var lastPoke: [UUID: Date] = [:]

    /// Bei offener App Freunde mit veralteter Position bitten, kurz ihren Standort zu senden.
    private func requestFreshPositions() {
        guard UIApplication.shared.applicationState == .active else { return }
        let now = Date()
        var ids: [UUID] = []
        for f in friends.accepted {
            guard let known = f.lastKnown else { continue }       // nur Freunde, die gerade teilen
            let age = hub.positions[f.friendId]?.age ?? known.age
            if age > 120, now.timeIntervalSince(lastPoke[f.friendId] ?? .distantPast) > 240 {
                ids.append(f.friendId)
                lastPoke[f.friendId] = now
            }
        }
        if !ids.isEmpty { push.requestLocations(of: ids) }
    }

    /// Ein Freund hat per stillem Push nach meinem Standort gefragt: Sitzung sicherstellen, Position holen, senden.
    func answerLocateRequest() async -> Bool {
        if profile == nil {
            // Start im Hintergrund: Anmeldung laden (start() läuft dauerhaft, deshalb nicht abwarten)
            Task { await auth.start() }
            for _ in 0..<40 where profile == nil { try? await Task.sleep(for: .milliseconds(200)) }
        }
        await startSession()
        guard let profile, profile.isSharingNow else { return false }
        guard let fix = await location.currentFix(timeout: 12) else { return false }
        await hub.publish(fix, userId: profile.id, sharingEnabled: true, force: true)
        return true
    }

    // MARK: Inkognito

    /// Für Freunde unsichtbar: Standort und Route. `duration` nil = bis zum Ausschalten.
    func startIncognito(for duration: TimeInterval?) async {
        guard let profile else { return }
        await hub.announceGone(userId: profile.id)
        let until = Date().addingTimeInterval(duration ?? 50 * 365 * 86400)
        await auth.setIncognito(until: until)
        guard self.profile?.isIncognito == true else { return }
        location.refreshMode()
        await routes.clearMine()
        show("Inkognito aktiv – Freunde sehen weder deinen Standort noch deine Route.", isError: false)
    }

    func stopIncognito() async {
        await auth.setIncognito(until: nil)
        location.refreshMode()
        show("Inkognito beendet – du bist für Freunde wieder sichtbar.", isError: false)
    }

    func setHideRoutes(_ hide: Bool) async {
        await auth.setHideRoutes(hide)
        if hide { await routes.clearMine() }
    }

    private func onLocation(_ loc: CLLocation) async {
        guard let profile else { return }
        await hub.publish(loc, userId: profile.id, sharingEnabled: profile.isSharingNow)
        await checkSoundMoments(me: loc)
    }

    // MARK: Sound-Pack-Momente

    @ObservationIgnored private var announced = Set<String>()

    /// Prüft bei jeder eigenen Positionsmeldung, ob ein Schnipsel fällig ist.
    private func checkSoundMoments(me loc: CLLocation) async {
        guard sounds.enabled else { return }
        let myMoving = loc.speed > 3          // > ~11 km/h

        for f in friendsOnMap where f.position.age < 45 {
            let friendPos = CLLocation(latitude: f.position.lat, longitude: f.position.lng)
            let dist = loc.distance(from: friendPos)
            let friendSpeed = f.position.speed ?? 0

            // 1. Freund fährt an mir vorbei: beide unterwegs, < 300 m, höchstens alle 15 Min.
            if myMoving, friendSpeed > 3, dist < 300 {
                await sounds.trigger(.pass, friend: f.friend, cooldown: 15 * 60)
            }

            // 2./3. Treffpunkt: Freund etwa 5 Min. entfernt bzw. angekommen (je Treffen einmal)
            for m in meetups.accepted where m.otherId == f.friend.friendId {
                let d = f.position.coordinate.distance(to: m.coordinate)
                let arrivedKey = "arrived-\(m.id)"
                let soonKey = "soon-\(m.id)"
                if d < 100, !announced.contains(arrivedKey) {
                    announced.insert(arrivedKey)
                    announced.insert(soonKey)
                    await sounds.trigger(.arrived, friend: f.friend, key: m.id.uuidString)
                } else if d > 150, !announced.contains(soonKey) {
                    let eta = d / max(friendSpeed, 8)       // mind. ~29 km/h als Annahme
                    if eta < 300 {
                        announced.insert(soonKey)
                        await sounds.trigger(.soon, friend: f.friend, key: m.id.uuidString)
                    }
                }
            }
        }
    }

    func signOut() async {
        await endSession()
        await auth.signOut()
    }

    func deleteAccount() async {
        if let id = auth.profile?.id {
            await avatars.deleteFile(userId: id)
            await sounds.deleteFiles(userId: id)
        }
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
