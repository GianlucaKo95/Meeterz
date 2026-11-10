import Foundation
import Observation
import Supabase

/// Kurznachrichten unter Freunden: Schnellantworten (auch aus CarPlay) und automatische Verspätungsmeldung.
/// Kein Chat-Verlauf – der Server liefert nur die letzten 12 Stunden.
@MainActor @Observable
final class MessagesStore {
    struct Message: Decodable, Identifiable, Equatable {
        let id: UUID
        let otherId: UUID
        let otherName: String
        let incoming: Bool
        let body: String
        let meetupId: UUID?
        let automatic: Bool
        let createdAt: Date

        var firstName: String { otherName.split(separator: " ").first.map(String.init) ?? otherName }

        enum CodingKeys: String, CodingKey {
            case id, body, incoming, automatic
            case otherId = "other_id"
            case otherName = "other_name"
            case meetupId = "meetup_id"
            case createdAt = "created_at"
        }
    }

    private(set) var messages: [Message] = []

    /// Bei Verspätung von 5 Minuten oder mehr automatisch Bescheid geben (Einstellung, Standard an)
    static var autoDelay: Bool {
        get { UserDefaults.standard.object(forKey: "messages.autoDelay") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "messages.autoDelay") }
    }

    @ObservationIgnored private var seen = Set<UUID>()
    @ObservationIgnored private var loadedOnce = false
    @ObservationIgnored private var feed: RealtimeFeed?
    private var client: SupabaseClient { Backend.client }

    var incoming: [Message] { messages.filter(\.incoming) }

    // MARK: Empfangen

    func startListening(userId: UUID) async {
        guard feed == nil else { return }
        // refresh() kennt schon gesehene Nachrichten – auch bei Änderungen statt nur neuen Zeilen harmlos
        let feed = RealtimeFeed(topic: "messages-\(userId.uuidString.lowercased())", table: "messages") { [weak self] in
            await self?.refresh()
        }
        self.feed = feed
        await feed.start()
        await refresh()
    }

    func stopListening() async {
        await feed?.stop()
        feed = nil
        messages = []
        seen = []
        loadedOnce = false
    }

    func refresh() async {
        guard let rows: [Message] = try? await client.rpc("my_messages").execute().value else { return }
        let fresh = rows.filter { $0.incoming && !seen.contains($0.id) }
        rows.forEach { seen.insert($0.id) }
        messages = rows
        // Beim ersten Laden nichts nachmelden – nur, was neu ankommt
        if loadedOnce {
            for m in fresh.reversed() where Date().timeIntervalSince(m.createdAt) < 10 * 60 { deliver(m) }
        }
        loadedOnce = true
    }

    private func deliver(_ m: Message) {
        AppModel.shared.show("\(m.firstName): \(m.body)", isError: false)
        CarPlayController.shared.messageReceived(m)
        // Automatische Verspätung: kam sie gerade schon als Moment „verspätet sich“, nicht noch einmal vorlesen
        if m.automatic {
            if AppModel.shared.lateRecentlyNotified(m.otherId) { return }
            AppModel.shared.noteLateNotified(m.otherId)
        }
        // Im Auto vorlesen (Musik wird kurz leiser, Navigationsansagen laufen weiter)
        if CarPlayController.shared.isConnected {
            AppModel.shared.sounds.announce(String(localized: "\(m.firstName) schreibt: \(m.body)"))
        }
    }

    // MARK: Senden

    @discardableResult
    func send(_ body: String, to ids: [UUID], meetupId: UUID? = nil, automatic: Bool = false) async -> Int {
        struct Params: Encodable { let to_user_id: UUID; let body: String; let meetup_id: UUID?; let automatic: Bool }
        var sent = 0
        for id in Set(ids) {
            do {
                let messageId: UUID = try await client.rpc("send_message", params: Params(
                    to_user_id: id, body: body, meetup_id: meetupId, automatic: automatic)).execute().value
                AppModel.shared.push.notify(.message, to: id, messageId: messageId)
                sent += 1
            } catch {
                Diag.log("Nachricht nicht gesendet: \(error.localizedDescription)")
            }
        }
        await refresh()
        return sent
    }

    /// Vorgefertigte Antworten – mit Ankunftszeit, wenn gerade navigiert wird
    static func quickReplies(eta: Date?) -> [String] {
        var replies: [String] = []
        if let eta { replies.append(String(localized: "Bin um \(ActivityFormat.time(eta)) da")) }
        replies += [
            String(localized: "Bin gleich da"),
            String(localized: "Bin unterwegs"),
            String(localized: "Komme ca. 10 Min. später"),
            String(localized: "Stehe im Stau"),
            String(localized: "Bin da – wo seid ihr?"),
            String(localized: "Fangt schon ohne mich an"),
            String(localized: "Alles klar 👍"),
        ]
        return replies
    }
}
