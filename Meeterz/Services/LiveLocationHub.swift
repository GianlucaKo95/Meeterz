import Foundation
import CoreLocation
import Observation
import Supabase

/// Sendet die eigene Position in den privaten Kanal "loc:<eigene id>"
/// und hört auf die Kanäle aller Freunde. RLS (realtime.messages) sorgt dafür,
/// dass nur Freunde mit aktivem Teilen empfangen werden können.
@MainActor @Observable
final class LiveLocationHub {
    /// Neueste bekannte Position je Freund (Live oder Seed aus last_locations)
    private(set) var positions: [UUID: LivePosition] = [:]

    @ObservationIgnored private var ownChannel: RealtimeChannelV2?
    @ObservationIgnored private var friendChannels: [UUID: RealtimeChannelV2] = [:]
    @ObservationIgnored private var listeners: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var goneListeners: [UUID: Task<Void, Never>] = [:]
    /// Freunde, die ich zuletzt unsichtbar gesehen habe (Kanal-Beitritt war dann evtl. verwehrt)
    @ObservationIgnored private var seenHidden = Set<UUID>()
    @ObservationIgnored private var lastSent: LivePosition?
    @ObservationIgnored private var lastPersisted = Date.distantPast

    private var client: SupabaseClient { Backend.client }

    private static func topic(_ id: UUID) -> String { "loc:\(id.uuidString.lowercased())" }

    // MARK: Senden

    func startPublishing(userId: UUID) async {
        guard ownChannel == nil else { return }
        let ch = client.channel(Self.topic(userId)) {
            $0.isPrivate = true
            $0.broadcast.receiveOwnBroadcasts = false
        }
        try? await ch.subscribeWithError()
        ownChannel = ch
    }

    /// Inkognito startet: Freunde lassen mich sofort von ihrer Karte verschwinden.
    /// Muss VOR dem Setzen des Inkognito-Flags in der Datenbank aufgerufen werden.
    func announceGone(userId: UUID) async {
        struct Gone: Codable { let userId: UUID }
        try? await ownChannel?.broadcast(event: "gone", message: Gone(userId: userId))
        lastSent = nil                      // nach dem Inkognito sofort wieder senden
        lastPersisted = .distantPast
    }

    func publish(_ loc: CLLocation, userId: UUID, sharingEnabled: Bool, force: Bool = false) async {
        guard sharingEnabled, let ch = ownChannel else { return }

        let pos = LivePosition(
            userId: userId,
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            heading: loc.course >= 0 ? loc.course : nil,
            speed: loc.speed >= 0 ? loc.speed : nil,
            ts: loc.timestamp.timeIntervalSince1970
        )
        guard force || shouldSend(pos) else { return }

        do {
            try await ch.broadcast(event: "pos", message: pos)
            lastSent = pos
        } catch {
            // Nächstes Update versucht es erneut
        }

        // Letzte Position seltener dauerhaft speichern (für App-Start der Freunde)
        if force || Date().timeIntervalSince(lastPersisted) > 120 {
            lastPersisted = Date()
            struct Params: Encodable { let lat, lng: Double; let heading, speed: Double? }
            _ = try? await client.rpc("update_last_location",
                                      params: Params(lat: pos.lat, lng: pos.lng,
                                                     heading: pos.heading, speed: pos.speed)).execute()
        }
    }

    /// Adaptive Rate: in Fahrt ca. alle 5 s, im Stand höchstens jede Minute.
    private func shouldSend(_ pos: LivePosition) -> Bool {
        guard let last = lastSent else { return true }
        let elapsed = pos.ts - last.ts
        let moving = (pos.speed ?? 0) > 2
        let distance = CLLocation(latitude: pos.lat, longitude: pos.lng)
            .distance(from: CLLocation(latitude: last.lat, longitude: last.lng))
        return moving ? (elapsed >= 5 || distance >= 50) : (elapsed >= 60 || distance >= 30)
    }

    // MARK: Empfangen

    /// Übernimmt letzte bekannte Positionen und gleicht Abos mit der Freundesliste ab.
    func sync(with friends: [FriendRow]) async {
        let accepted = friends.filter(\.isAccepted)
        let ids = Set(accepted.map(\.friendId))

        for f in accepted {
            if let seed = f.lastKnown {
                if (positions[f.friendId]?.ts ?? 0) < seed.ts { positions[f.friendId] = seed }
                // Wieder sichtbar nach Unsichtbarkeit: Kanal neu betreten, falls der Beitritt verwehrt war
                if seenHidden.remove(f.friendId) != nil, friendChannels[f.friendId] != nil {
                    await resubscribe(f.friendId)
                }
            } else {
                // Nicht (mehr) sichtbar: veraltete Live-Position entfernen
                seenHidden.insert(f.friendId)
                if let p = positions[f.friendId], p.age > 150 { positions.removeValue(forKey: f.friendId) }
            }
        }

        for id in friendChannels.keys where !ids.contains(id) {
            await unsubscribe(id)
        }
        for id in ids where friendChannels[id] == nil {
            await subscribe(id)
        }
    }

    private func subscribe(_ friendId: UUID) async {
        let ch = client.channel(Self.topic(friendId)) { $0.isPrivate = true }
        let stream = ch.broadcastStream(event: "pos")
        let goneStream = ch.broadcastStream(event: "gone")
        friendChannels[friendId] = ch
        do { try await ch.subscribeWithError() } catch { seenHidden.insert(friendId) }

        goneListeners[friendId] = Task { [weak self] in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            struct Gone: Decodable { let userId: UUID }
            for await message in goneStream {
                guard let payload = message["payload"],
                      let data = try? encoder.encode(payload),
                      let gone = try? decoder.decode(Gone.self, from: data),
                      gone.userId == friendId
                else { continue }
                self?.positions.removeValue(forKey: friendId)
            }
        }

        listeners[friendId] = Task { [weak self] in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            for await message in stream {
                guard let payload = message["payload"],
                      let data = try? encoder.encode(payload),
                      let pos = try? decoder.decode(LivePosition.self, from: data),
                      pos.userId == friendId
                else { continue }
                self?.positions[friendId] = pos
            }
        }
    }

    private func unsubscribe(_ friendId: UUID) async {
        await closeChannel(friendId)
        positions.removeValue(forKey: friendId)
        seenHidden.remove(friendId)
    }

    private func closeChannel(_ friendId: UUID) async {
        listeners.removeValue(forKey: friendId)?.cancel()
        goneListeners.removeValue(forKey: friendId)?.cancel()
        if let ch = friendChannels.removeValue(forKey: friendId) {
            await client.removeChannel(ch)
        }
    }

    private func resubscribe(_ friendId: UUID) async {
        await closeChannel(friendId)
        await subscribe(friendId)
    }

    func stopAll() async {
        for id in Array(friendChannels.keys) { await unsubscribe(id) }
        if let ch = ownChannel { await client.removeChannel(ch) }
        ownChannel = nil
        lastSent = nil
    }
}
