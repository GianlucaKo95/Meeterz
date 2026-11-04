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

    init(topic: String, table: String, filter: RealtimePostgresFilter? = nil, onChange: @escaping @MainActor () async -> Void) {
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
                        if joined { Diag.log("Live-Verbindung \(topic) wieder da"); await self?.onChange() }
                        joined = true
                    case .unsubscribed where joined:
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
            await self.onChange()
        }
    }

    private func teardown() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        if let ch = channel { await Backend.client.removeChannel(ch) }
        channel = nil
    }
}
