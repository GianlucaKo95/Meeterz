import Foundation
import CoreLocation
import Observation
import Supabase

/// Konvoi-Feed: was während einer gemeinsamen Fahrt passiert (dazugekommen, Pause, Laden, Nachricht, Story, angekommen).
/// Bleibt danach als Fahrt-Chronik unter „Fahrten“. Alle Mitfahrenden bilden denselben Schlüssel: die Treffen-ID,
/// sonst das auf ~1 km gerundete Ziel plus Datum.
@MainActor @Observable
final class ConvoyFeed {
    static let shared = ConvoyFeed()

    enum Kind: String, Codable { case joined, pause, charge, message, story, arrived }

    struct Event: Decodable, Identifiable, Equatable {
        let id: UUID
        let convoyKey: String
        let userId: UUID
        let kind: Kind
        let text: String?
        let destName: String?
        let storyId: UUID?
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, kind, text
            case convoyKey = "convoy_key"
            case userId = "user_id"
            case destName = "dest_name"
            case storyId = "story_id"
            case createdAt = "created_at"
        }
    }

    struct Trip: Decodable, Identifiable, Equatable {
        let convoyKey: String
        let destName: String?
        let startedAt: Date
        let lastAt: Date
        let members: [UUID]
        let entries: Int
        var id: String { convoyKey }

        enum CodingKeys: String, CodingKey {
            case members, entries
            case convoyKey = "convoy_key"
            case destName = "dest_name"
            case startedAt = "started_at"
            case lastAt = "last_at"
        }
    }

    /// Laufender Konvoi (nil = ich fahre gerade mit niemandem)
    private(set) var key: String?
    private(set) var trips: [Trip] = []
    /// Einträge des gerade angezeigten Feeds
    private(set) var entries: [Event] = []
    private(set) var shownKey: String?

    @ObservationIgnored private var members = Set<UUID>()
    @ObservationIgnored private var destName: String?
    @ObservationIgnored private var destination: CLLocationCoordinate2D?
    @ObservationIgnored private var feed: RealtimeFeed?
    private var client: SupabaseClient { Backend.client }
    private var app: AppModel { AppModel.shared }

    // MARK: Laufender Konvoi

    /// Alle 30 s (AppModel): Konvoi erkennen, Mitfahrende sammeln, „dazugekommen“ einmal je Fahrt
    func update() {
        let current = ConvoyTracker.shared.members().map(\.friend.friendId)
        guard app.navigation.isNavigating, let dest = app.navigation.destination, !current.isEmpty else { return }
        let newKey = Self.key(for: dest.coordinate, meetups: app.meetups.accepted)
        if newKey != key { key = newKey; members = [] }
        members.formUnion(current)
        destName = dest.name
        destination = dest.coordinate
        let joined = "convoy.joined.\(newKey)"
        if !UserDefaults.standard.bool(forKey: joined) {
            UserDefaults.standard.set(true, forKey: joined)
            post(.joined)
        }
    }

    /// Navigation endet: am Ziel „angekommen“ eintragen, dann ist der Konvoi vorbei
    func navigationEnded() {
        guard key != nil else { return }
        if let destination, let here = app.location.lastLocation?.coordinate, here.distance(to: destination) < 400 {
            post(.arrived)
        }
        key = nil
        members = []
    }

    func post(_ kind: Kind, text: String? = nil, storyId: UUID? = nil) {
        guard let key, !members.isEmpty else { return }
        struct Row: Encodable {
            let convoy_key: String; let members: [UUID]; let kind: String; let text: String?
            let dest_name: String?; let story_id: UUID?; let lat: Double?; let lng: Double?
        }
        let here = app.location.lastLocation?.coordinate
        let row = Row(convoy_key: key, members: Array(members.prefix(20)), kind: kind.rawValue, text: text.map { String($0.prefix(200)) },
                      dest_name: destName, story_id: storyId, lat: here?.latitude, lng: here?.longitude)
        Task {
            do { try await client.from("convoy_events").insert(row).execute() }
            catch { Diag.log("Konvoi-Feed: \(kind.rawValue) nicht gespeichert – \(error.localizedDescription)") }
            if shownKey == key { await load(key) }
        }
    }

    /// Nachricht an Mitfahrende auch in den Feed
    func messageSent(_ body: String, to ids: [UUID]) {
        guard key != nil, !ids.isEmpty, Set(ids).isSubset(of: members) else { return }
        post(.message, text: body)
    }

    // ponytail: Ziel auf 2 Nachkommastellen – liegt es genau auf einer Rundungsgrenze, bekommen Mitfahrende verschiedene Feeds
    static func key(for destination: CLLocationCoordinate2D, meetups: [Meetup]) -> String {
        if let meetup = meetups.first(where: { $0.coordinate.distance(to: destination) < 300 }) {
            return "m-\(meetup.id.uuidString.lowercased())"
        }
        let day = Date().formatted(.iso8601.year().month().day())
        return String(format: "d-%.2f,%.2f-", destination.latitude, destination.longitude) + day
    }

    // MARK: Anzeigen

    func startListening(userId: UUID) async {
        guard feed == nil else { return }
        let feed = RealtimeFeed(topic: "convoy-\(userId.uuidString.lowercased())", table: "convoy_events") { [weak self] in
            guard let self else { return }
            if let shown = self.shownKey { await self.load(shown) }
        }
        self.feed = feed
        await feed.start()
    }

    func stopListening() async {
        await feed?.stop()
        feed = nil
        key = nil
        members = []
        trips = []
        entries = []
        shownKey = nil
    }

    func loadTrips() async {
        if let rows: [Trip] = try? await client.rpc("my_convoys").execute().value { trips = rows }
    }

    func show(_ key: String?) async {
        shownKey = key
        entries = []
        if let key { await load(key) }
    }

    private func load(_ key: String) async {
        guard let rows: [Event] = try? await client.from("convoy_events")
            .select("id,convoy_key,user_id,kind,text,dest_name,story_id,created_at")
            .eq("convoy_key", value: key).order("created_at").execute().value, shownKey == key else { return }
        entries = rows
    }

    /// Anzeigetext eines Eintrags
    func describe(_ e: Event) -> String {
        let me = e.userId == app.profile?.id
        let name = me ? String(localized: "Du") : (app.friends.rows.first { $0.friendId == e.userId }?.firstName ?? String(localized: "Jemand"))
        switch e.kind {
        case .joined: return me ? String(localized: "Du bist losgefahren") : String(localized: "\(name) fährt mit")
        case .pause: return String(localized: "\(name) schlägt eine Pause vor: \(e.text ?? "")")
        case .charge: return me ? String(localized: "Du lädst") : String(localized: "\(name) lädt")
        case .message: return "\(name): \(e.text ?? "")"
        case .story: return me ? String(localized: "Du hast eine Story geteilt") : String(localized: "\(name) hat eine Story geteilt")
        case .arrived: return me ? String(localized: "Du bist angekommen") : String(localized: "\(name) ist angekommen")
        }
    }
}
