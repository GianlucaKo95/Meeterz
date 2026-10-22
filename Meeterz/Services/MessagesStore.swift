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
    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var listener: Task<Void, Never>?
    private var client: SupabaseClient { Backend.client }

    var incoming: [Message] { messages.filter(\.incoming) }

    // MARK: Empfangen

    func startListening(userId: UUID) async {
        guard channel == nil else { return }
        let ch = client.channel("messages-\(userId.uuidString.lowercased())")
        let changes = ch.postgresChange(InsertAction.self, schema: "public", table: "messages")
        channel = ch
        try? await ch.subscribeWithError()
        listener = Task { [weak self] in
            for await _ in changes { await self?.refresh() }
        }
        await refresh()
    }

    func stopListening() async {
        listener?.cancel()
        listener = nil
        if let ch = channel { await client.removeChannel(ch) }
        channel = nil
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
        // Im Auto vorlesen (Musik wird kurz leiser, Navigationsansagen laufen weiter)
        if CarPlayController.shared.isConnected {
            AppModel.shared.sounds.announce("\(m.firstName) schreibt: \(m.body)")
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
        if let eta { replies.append("Bin um \(Format.time.string(from: eta)) da") }
        replies += [
            "Bin gleich da",
            "Bin unterwegs",
            "Komme ca. 10 Min. später",
            "Stehe im Stau",
            "Bin da – wo seid ihr?",
            "Fangt schon ohne mich an",
            "Alles klar 👍",
        ]
        return replies
    }
}
