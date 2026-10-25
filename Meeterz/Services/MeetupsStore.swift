import Foundation
import CoreLocation
import Observation
import Supabase

/// Treffpunkt-Erkennung und Treffen-Vorschläge.
@MainActor @Observable
final class MeetupsStore {
    /// Automatisch erkannte Gelegenheiten (Routen kreuzen sich zeitlich)
    private(set) var candidates: [MeetupCandidate] = []
    /// Offene und angenommene Vorschläge
    private(set) var meetups: [Meetup] = []
    /// Vom Nutzer weggeklickte Gelegenheiten (pro Freund, bis sich die Situation ändert)
    private var dismissed: [UUID: Date] = [:]
    @ObservationIgnored private var wasFetched = false

    var incomingPending: [Meetup] { meetups.filter { $0.incoming && $0.isPending } }
    var outgoingPending: [Meetup] { meetups.filter { !$0.incoming && $0.isPending } }
    var accepted: [Meetup] { meetups.filter(\.isAccepted) }

    /// Gelegenheiten ohne offenen Vorschlag und nicht weggeklickt
    var visibleCandidates: [MeetupCandidate] {
        candidates.filter { c in
            !meetups.contains { $0.otherId == c.friendId }
                && (dismissed[c.friendId].map { Date().timeIntervalSince($0) > 30 * 60 } ?? true)
        }
    }

    private var client: SupabaseClient { Backend.client }
    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var listener: Task<Void, Never>?

    // MARK: Live-Updates für Vorschläge

    func startListening(userId: UUID) async {
        guard channel == nil else { return }
        let ch = client.channel("meetups-\(userId.uuidString.lowercased())")
        let changes = ch.postgresChange(AnyAction.self, schema: "public", table: "meetups")
        channel = ch
        try? await ch.subscribeWithError()
        listener = Task { [weak self] in
            for await _ in changes {
                await self?.refreshMeetups()
            }
        }
    }

    func stopListening() async {
        listener?.cancel()
        listener = nil
        if let ch = channel { await client.removeChannel(ch) }
        channel = nil
        candidates = []
        meetups = []
    }

    // MARK: Laden

    func refresh() async {
        await refreshMeetups()
        do {
            candidates = try await client.rpc("find_meetups").execute().value
        } catch {
            // ohne Netz bleibt der letzte Stand
        }
    }

    private func refreshMeetups() async {
        if let rows: [Meetup] = try? await client.rpc("my_meetups").execute().value {
            // 4. Freund nimmt meinen Vorschlag an → sein Schnipsel abspielen
            let wasPending = Set(meetups.filter { !$0.incoming && $0.isPending }.map(\.id))
            let hadBefore = !meetups.isEmpty || wasFetched
            wasFetched = true
            if hadBefore {
                for m in rows where !m.incoming && m.isAccepted && wasPending.contains(m.id) {
                    if let f = AppModel.shared.friend(m.otherId) {
                        CarPlayController.shared.friendNotice(.accepted, friend: f)
                        Task { await AppModel.shared.sounds.trigger(.accepted, friend: f, key: m.id.uuidString) }
                    }
                }
            }
            let changed = meetups != rows
            meetups = rows
            if changed { WidgetSnapshotWriter.shared.update(force: true) }
            Task { await DepartureReminder.shared.refresh() }
        }
    }

    func dismiss(_ candidate: MeetupCandidate) {
        dismissed[candidate.friendId] = Date()
    }

    // MARK: Aktionen

    func propose(to friendId: UUID, place: Place, at meetAt: Date? = nil, silent: Bool = false) async -> Bool {
        // meet_at nur mitschicken, wenn gesetzt (synthetisiertes Encodable lässt nil weg)
        struct Params: Encodable { let to_user_id: UUID; let place_name: String; let lat: Double; let lng: Double; let meet_at: Date? }
        do {
            let id: UUID = try await client.rpc("propose_meetup", params: Params(
                to_user_id: friendId, place_name: place.name,
                lat: place.coordinate.latitude, lng: place.coordinate.longitude, meet_at: meetAt
            )).execute().value
            AppModel.shared.push.notify(.meetupProposed, to: friendId, meetupId: id)
            await refreshMeetups()
            return true
        } catch {
            if !silent { AppModel.shared.show("Vorschlag konnte nicht gesendet werden.") }
            return false
        }
    }

    /// Gruppen-Treffen: ein Ort, Einladung an mehrere Freunde (jeder antwortet für sich)
    func proposeGroup(to friendIds: [UUID], place: Place) async -> Bool {
        struct Params: Encodable { let friend_ids: [UUID]; let place_name: String; let lat: Double; let lng: Double }
        do {
            let _: UUID = try await client.rpc("propose_group_meetup", params: Params(
                friend_ids: friendIds, place_name: place.name,
                lat: place.coordinate.latitude, lng: place.coordinate.longitude
            )).execute().value
            await refreshMeetups()
            for id in friendIds {
                let meetupId = meetups.first { !$0.incoming && $0.otherId == id && $0.isPending }?.id
                AppModel.shared.push.notify(.meetupProposed, to: id, meetupId: meetupId)
            }
            return true
        } catch {
            AppModel.shared.show("Gruppen-Treffen konnte nicht gesendet werden.")
            return false
        }
    }

    struct GroupMember: Decodable, Identifiable {
        let userId: UUID
        let displayName: String
        let status: String
        let organizer: Bool
        var id: UUID { userId }
        enum CodingKeys: String, CodingKey {
            case userId = "user_id", displayName = "display_name", status, organizer
        }
    }

    func groupMembers(_ groupId: UUID) async -> [GroupMember] {
        (try? await client.rpc("group_members", params: ["gid": groupId]).execute().value) ?? []
    }

    func respond(_ meetup: Meetup, accept: Bool) async {
        struct Params: Encodable { let meetup_id: UUID; let accept: Bool }
        do {
            try await client.rpc("respond_meetup", params: Params(meetup_id: meetup.id, accept: accept)).execute()
            AppModel.shared.push.notify(accept ? .meetupAccepted : .meetupDeclined, to: meetup.otherId, meetupId: meetup.id)
            await refreshMeetups()
        } catch {
            AppModel.shared.show("Antwort konnte nicht gesendet werden.")
        }
    }

    func cancel(_ meetup: Meetup) async {
        _ = try? await client.rpc("cancel_meetup", params: ["meetup_id": meetup.id]).execute()
        await refreshMeetups()
    }
}
