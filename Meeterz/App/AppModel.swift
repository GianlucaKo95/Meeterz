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
    let messages = MessagesStore()
    let parking = ParkingStore()
    let vehicle = VehicleStore()
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
    /// Auf der Karte angetippter Freund (öffnet das Aktionsfenster)
    var selectedFriend: UUID?

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
        // Beim ersten Mal mit Erklärseite (Standort, dann Mitteilungen, dann Bewegung fürs Parken), sonst direkt
        if location.authorization != .notDetermined { location.requestPermission() }

        await hub.startPublishing(userId: profile.id)
        await meetups.startListening(userId: profile.id)
        MeetupLiveActivityController.shared.start()
        NavigationLiveActivityController.shared.watch()
        await messages.startListening(userId: profile.id)
        await vehicle.startListening(userId: profile.id)
        Task { @MainActor in
            if self.location.authorization == .notDetermined { _ = await Permissions.ask(.location) }
            _ = await Permissions.ask(.notifications)
            if ParkingStore.enabled, await Permissions.ask(.motion) { ParkingDetector.shared.start() }
        }

        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSocial()
                _ = await RouteSuggestions.shared.refresh()   // für das Widget „Nächstes Ziel“ (höchstens alle 5 Min.)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func endSession() async {
        WidgetSnapshotWriter.shared.clear()
        avatars.reset()
        sounds.reset()
        favorites.reset()
        recents.reset()
        refreshLoop?.cancel()
        refreshLoop = nil
        MeetupLiveActivityController.shared.stop()
        sessionUser = nil
        location.onUpdate = nil
        navigation.stop()
        await hub.stopAll()
        await meetups.stopListening()
        await messages.stopListening()
        await vehicle.stopListening()
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
        await checkMeetupJourneys()
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

    /// Start ohne iPhone-Oberfläche (CarPlay startet Meeterz im Hintergrund): Anmeldung und Sitzung hochfahren wie beim
    /// normalen App-Start. Sonst lief das nur über RootView/MainView – ohne geöffnete App gab es keine Anmeldung, keine
    /// Freunde und keine Favoriten, das Dashboard hatte keine Knöpfe und CarPlay zeigte dort nur das App-Symbol.
    func startWithoutPhoneUI(_ reason: String) {
        guard !headlessStarted else { return }
        headlessStarted = true
        Task { await auth.start() }   // läuft dauerhaft (Anmeldeereignisse) – nicht abwarten
        Task { [weak self] in
            let started = Date()
            // Profil abwarten (ohne Netz versucht AuthStore es selbst erneut)
            while self?.profile == nil, Date().timeIntervalSince(started) < 300 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self else { return }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            guard self.profile != nil else {
                Diag.log("Start ohne App (\(reason)): nach \(seconds) s noch keine Anmeldung")
                return
            }
            await self.startSession()
            Diag.log("Start ohne App (\(reason)): Sitzung nach \(seconds) s, \(self.friends.accepted.count) Freunde")
        }
    }
    private var headlessStarted = false

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
        show(String(localized: "Inkognito aktiv – Freunde sehen weder deinen Standort noch deine Route."), isError: false)
    }

    func stopIncognito() async {
        await auth.setIncognito(until: nil)
        location.refreshMode()
        show(String(localized: "Inkognito beendet – du bist für Freunde wieder sichtbar."), isError: false)
    }

    /// Standort teilen für die gewählte Dauer (Profil, Karte, Siri)
    func shareLocation(for mode: SharingMode) async {
        SharingMode.current = mode
        if profile?.isIncognito == true { await stopIncognito() }
        await auth.setSharing(true, until: mode.until(eta: navigation.eta))
    }

    func setHideRoutes(_ hide: Bool) async {
        await auth.setHideRoutes(hide)
        if hide { await routes.clearMine() }
    }

    private func onLocation(_ loc: CLLocation) async {
        guard let profile else { return }
        await hub.publish(loc, userId: profile.id, sharingEnabled: profile.isSharingNow)
        await checkSoundMoments(me: loc)
        await meetups.checkArrival(at: loc)
        WidgetSnapshotWriter.shared.update()
    }

    // MARK: Sound-Pack-Momente

    @ObservationIgnored private var announced = Set<String>()
    /// Letzte Begegnung je Freund (höchstens alle 15 Minuten eine)
    @ObservationIgnored private var lastEncounter: [UUID: Date] = [:]
    /// Treffen, bei denen der Freund schon einmal deutlich entfernt war (> 300 m) – erst dann sind „gleich da“
    /// und „angekommen“ echte Ereignisse. Wer schon dort ist (Treffen bei ihm zu Hause), „kommt“ nicht „an“.
    @ObservationIgnored private var meetupAway = Set<String>()
    /// Letzter Abstand je Treffen und Freund (nähert er sich?)
    @ObservationIgnored private var meetupDistance: [String: Double] = [:]

    /// Treffpartner unterwegs: hatte er beim letzten Blick eine Route zum Treffpunkt? (Schlüssel Treffen-Freund)
    @ObservationIgnored private var journeyRoute: [String: Bool] = [:]
    /// Erste gesehene Ankunft (ohne verabredete Uhrzeit der Maßstab für „verspätet sich“)
    @ObservationIgnored private var lateBaseline: [String: Date] = [:]
    /// Zuletzt als verspätet gemeldete Ankunft
    @ObservationIgnored private var lateAnnounced: [String: Date] = [:]
    /// Wann zuletzt eine Verspätung je Freund gemeldet wurde – als Moment oder als automatische Nachricht
    /// (nicht beides kurz hintereinander)
    @ObservationIgnored private var lateNotified: [UUID: Date] = [:]

    /// Kam für diesen Freund gerade (≤ 3 Min.) schon eine Verspätung? Dann liest CarPlay die automatische Nachricht nicht vor.
    func lateRecentlyNotified(_ id: UUID) -> Bool { Date().timeIntervalSince(lateNotified[id] ?? .distantPast) < 180 }
    func noteLateNotified(_ id: UUID) { lateNotified[id] = Date() }

    /// „Ist losgefahren“ und „verspätet sich“ – aus den geteilten Routen der Treffpartner. Läuft bei jeder eigenen
    /// Positionsmeldung und bei jeder Aktualisierung (alle 30 s), damit es auch beim Wartenden im Stand ankommt.
    func checkMeetupJourneys() async {
        let now = Date()
        for m in meetups.accepted {
            if let at = m.meetAt, abs(at.timeIntervalSince(now)) > 3 * 3600 { continue }
            for id in meetups.partners(of: m) {
                guard let friend = friend(id) else { continue }
                let key = "\(m.id)-\(id)"
                let route = routes.route(of: id, to: m.coordinate)
                let had = journeyRoute[key]
                journeyRoute[key] = route != nil
                guard let route, route.eta > now else { continue }
                if lateBaseline[key] == nil { lateBaseline[key] = route.eta }

                // Verspätet: Ankunft 5 Min. nach der verabredeten Zeit (ohne Uhrzeit: nach der ersten gesehenen
                // Ankunft); danach erst wieder, wenn es noch einmal 10 Min. später wird
                let reference = lateAnnounced[key] ?? m.meetAt ?? lateBaseline[key]!
                let isLate = route.eta.timeIntervalSince(reference) >= (lateAnnounced[key] == nil ? 5 * 60 : 10 * 60)

                // Losgefahren: Route zum Treffpunkt ist neu (nicht schon beim ersten Blick da) und er war nicht schon dort
                let departedKey = "departed-\(key)"
                let alreadyThere = hub.positions[id].map { $0.coordinate.distance(to: m.coordinate) < 300 } ?? false
                if had == false, !announced.contains(departedKey), !alreadyThere {
                    announced.insert(departedKey)
                    if !isLate {
                        CarPlayController.shared.friendNotice(.departed, friend: friend, arrival: route.eta)
                        await sounds.trigger(.departed, friend: friend, key: m.id.uuidString)
                        continue
                    }
                }
                if isLate {
                    lateAnnounced[key] = route.eta
                    guard !lateRecentlyNotified(id) else { continue }   // automatische Nachricht kam gerade
                    noteLateNotified(id)
                    CarPlayController.shared.friendNotice(.late, friend: friend, arrival: route.eta)
                    await sounds.trigger(.late, friend: friend, key: "\(m.id)-\(Int(route.eta.timeIntervalSince1970))")
                }
            }
        }
    }

    /// Prüft bei jeder eigenen Positionsmeldung, ob ein Schnipsel fällig ist.
    /// Der Hinweis in CarPlay erscheint auch bei ausgeschaltetem Soundpaket (der Schnipsel prüft das selbst).
    private func checkSoundMoments(me loc: CLLocation) async {
        let myMoving = loc.speed > 3          // > ~11 km/h
        let now = Date()
        await checkMeetupJourneys()

        for f in friendsOnMap where f.position.age < 45 {
            let id = f.friend.friendId
            let friendSpeed = f.position.speed ?? 0
            Passengers.shared.observe(id, f.position)

            // 1. Begegnung: Freund fährt an mir vorbei (Gegenrichtung) oder einer holt zum anderen auf
            //    (gleiche Richtung, vorher weit weg) – höchstens alle 15 Min. je Freund. (Vorher Viertelstunden-Takt:
            //    an der Taktgrenze konnte dieselbe Begegnung zweimal kurz hintereinander kommen.)
            if myMoving, friendSpeed > 3, now.timeIntervalSince(lastEncounter[id] ?? .distantPast) > 15 * 60,
               let encounter = Passengers.shared.encounter(id) {
                lastEncounter[id] = now
                let moment: SoundMoment = encounter == .pass ? .pass : .catchUp
                CarPlayController.shared.friendNotice(moment, friend: f.friend)
                await sounds.trigger(moment, friend: f.friend, cooldown: 15 * 60)
            }

            // 2./3. Treffpunkt: Freund etwa 5 Min. entfernt bzw. angekommen (je Treffen einmal) – nur für Treffen,
            // die jetzt anstehen (ohne Uhrzeit oder höchstens 3 Stunden davor/danach), nicht für morgen
            for m in meetups.accepted where meetups.isPartner(id, in: m) {
                if let at = m.meetAt, abs(at.timeIntervalSince(now)) > 3 * 3600 { continue }
                let key = "\(m.id)-\(id)"
                let d = f.position.coordinate.distance(to: m.coordinate)
                let previous = meetupDistance[key]
                meetupDistance[key] = d
                if d > 300 { meetupAway.insert(key) }
                guard meetupAway.contains(key) else { continue }   // war nie weg: nichts anzukündigen
                let arrivedKey = "arrived-\(m.id)-\(id)"
                let soonKey = "soon-\(m.id)-\(id)"
                if d < 100, !announced.contains(arrivedKey) {
                    announced.insert(arrivedKey)
                    announced.insert(soonKey)
                    CarPlayController.shared.friendNotice(.arrived, friend: f.friend)
                    await sounds.trigger(.arrived, friend: f.friend, key: m.id.uuidString)
                } else if d > 150, !announced.contains(soonKey) {
                    // Fahrzeit: aus seiner geteilten Route zum Treffpunkt, sonst nur wenn er fährt und näher kommt
                    // (Luftlinie × 1,3 bei mind. ~29 km/h). Vorher reichte „weniger als 2,4 km weg“ – auch wer
                    // zu Hause in der Nähe saß, war dann angeblich „in fünf Minuten da“.
                    let eta: TimeInterval?
                    if let route = routes.route(of: id, to: m.coordinate) {
                        eta = route.eta.timeIntervalSince(now)
                    } else if friendSpeed > 2, let previous, d < previous - 20 {
                        eta = d * 1.3 / max(friendSpeed, 8)
                    } else {
                        eta = nil
                    }
                    if let eta, eta > 0, eta < 330 {
                        announced.insert(soonKey)
                        CarPlayController.shared.friendNotice(.soon, friend: f.friend)
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

    /// Sichtbare Freunde – ohne Mitfahrer (die gerade bei mir im Auto sitzen)
    var friendsOnMap: [FriendOnMap] {
        let riding = Passengers.shared.riding
        return friendsOnMapIncludingPassengers.filter { !riding.contains($0.friend.friendId) }
    }

    var friendsOnMapIncludingPassengers: [FriendOnMap] {
        let limit = StaleFriends.maxAge
        return friends.accepted.compactMap { f in
            hub.positions[f.friendId].map { FriendOnMap(friend: f, position: $0) }
        }
        // Lange nichts mehr gehört (kein Update, keine Antwort auf die Standortanfrage): von der Karte nehmen,
        // statt einen Stunden alten Standort zu zeigen. Kommt ein neuer Standort, ist der Freund sofort wieder da.
        .filter { limit == nil || $0.position.age <= limit! }
    }

    func friend(_ id: UUID) -> FriendRow? {
        friends.rows.first { $0.friendId == id }
    }
}

/// Freunde ohne aktuellen Standort nach einer einstellbaren Zeit ausblenden (Einstellungen → Karte)
enum StaleFriends {
    static let key = "map.hideStaleHours"
    static let choices = [1, 3, 6, 12, 24, 0]   // 0 = nie
    /// Stunden, nach denen ein Freund ohne neuen Standort verschwindet (Standard 6, 0 = nie)
    static var hours: Int {
        get { UserDefaults.standard.object(forKey: key) as? Int ?? 6 }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static var maxAge: TimeInterval? { hours > 0 ? TimeInterval(hours) * 3600 : nil }
}
