import Foundation
import Supabase

/// Live-Änderungen einer Tabelle, die nach einem Abbruch wiederkommen.
///
/// Schließt der Server den Kanal (z. B. Datenbank-Neustart am 04.11.), setzt supabase-swift ihn auf „unsubscribed“
/// und nimmt ihn aus der Liste – er wird nie wieder verbunden. Die App zeigte dann alte Werte, bis sie neu gestartet
/// wurde. Hier: neu abonnieren und nach jeder Wiederverbindung einmal alles laden (verpasste Änderungen).
@MainActor
final class RealtimeFeed {
    private let topic: String
    private let table: String
    private let filter: RealtimePostgresFilter?
    private let onChange: @MainActor () async -> Void
    private var channel: RealtimeChannelV2?
    private var tasks: [Task<Void, Never>] = []
    private var wanted = false
    private var reconnecting = false
    /// Seit wann die Verbindung weg ist – kurze Unterbrechungen (Server schließt den Kanal alle ~20 Min.) laden nicht
    /// alles neu; das waren je Wiederverbindung mehrere Anfragen (18.11.). Nachrichten: `catchUpAfter: 0`.
    private var lostAt: Date?
    private let catchUpAfter: TimeInterval

    init(topic: String, table: String, filter: RealtimePostgresFilter? = nil, catchUpAfter: TimeInterval = 60,
         onChange: @escaping @MainActor () async -> Void) {
        self.catchUpAfter = catchUpAfter
        self.topic = topic
        self.table = table
        self.filter = filter
        self.onChange = onChange
    }

    func start() async {
        wanted = true
        await connect()
    }

    func stop() async {
        wanted = false
        await teardown()
    }

    private func connect() async {
        guard wanted, channel == nil else { return }
        let ch = Backend.client.channel(topic)
        let changes = ch.postgresChange(AnyAction.self, schema: "public", table: table, filter: filter)
        channel = ch
        tasks = [
            Task { [weak self] in
                for await _ in changes { await self?.onChange() }
            },
            Task { [weak self, topic] in
                var joined = false
                for await status in ch.statusChange {
                    switch status {
                    case .subscribed:
                        // Nach einer Wiederverbindung des Sockets (rejoin): Verpasstes nachladen
                        if joined { Diag.log("Live-Verbindung \(topic) wieder da"); await self?.catchUp() }
                        joined = true
                        self?.lostAt = nil
                    case .subscribing, .unsubscribing:
                        if joined, self?.lostAt == nil { self?.lostAt = Date() }
                    case .unsubscribed where joined:
                        if self?.lostAt == nil { self?.lostAt = Date() }
                        Diag.log("Live-Verbindung \(topic) vom Server beendet – verbinde neu")
                        self?.scheduleReconnect()
                        return
                    default:
                        break
                    }
                }
            },
        ]
        do {
            try await ch.subscribeWithError()
        } catch {
            Diag.log("Live-Verbindung \(topic) fehlgeschlagen (\(error.localizedDescription)) – neuer Versuch")
            scheduleReconnect()
        }
    }

    /// Neuer Kanal nach kurzer Pause; danach einmal alles laden. Eigene Task: der Aufrufer wird beim Abbauen beendet.
    private func scheduleReconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        Task { [weak self] in
            guard let self else { return }
            await self.teardown()
            try? await Task.sleep(for: .seconds(10))
            self.reconnecting = false
            guard self.wanted, self.channel == nil else { return }
            await self.connect()
            await self.catchUp()
            self.lostAt = nil
        }
    }

    /// Verpasstes nachladen – nur wenn die Verbindung länger als `catchUpAfter` weg war
    private func catchUp() async {
        let gap = lostAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if gap >= catchUpAfter { await onChange() }
    }

    private func teardown() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        if let ch = channel { await Backend.client.removeChannel(ch) }
        channel = nil
    }
}
