import Foundation
import Observation
import Supabase

@MainActor @Observable
final class FriendsStore {
    private(set) var rows: [FriendRow] = []
    var errorMessage: String?

    var accepted: [FriendRow] { rows.filter(\.isAccepted) }
    var incoming: [FriendRow] { rows.filter { !$0.isAccepted && $0.incoming } }
    var outgoing: [FriendRow] { rows.filter { !$0.isAccepted && !$0.incoming } }

    private var client: SupabaseClient { Backend.client }

    func refresh() async {
        do {
            rows = try await client.rpc("my_friends").execute().value
            // Siri kennt die Namen der Freunde („Navigiere mit Meeterz zu Lisa“)
            MeeterzShortcuts.updateAppShortcutParameters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendRequest(handle: String) async -> Bool {
        let ok = await mutate {
            try await self.client.rpc("send_friend_request",
                                      params: ["target_handle": handle]).execute()
        }
        if ok, let target = rows.first(where: { $0.handle == handle.lowercased().trimmingCharacters(in: .whitespaces) }) {
            AppModel.shared.push.notify(.friendRequest, to: target.friendId)
        }
        return ok
    }

    func respond(to row: FriendRow, accept: Bool) async {
        struct Params: Encodable { let request_id: UUID; let accept: Bool }
        let ok = await mutate {
            try await self.client.rpc("respond_friend_request",
                                      params: Params(request_id: row.friendshipId, accept: accept)).execute()
        }
        if ok && accept {
            AppModel.shared.push.notify(.friendAccepted, to: row.friendId)
            await AppModel.shared.hub.sync(with: rows)
        }
    }

    func remove(_ row: FriendRow) async {
        _ = await mutate {
            try await self.client.rpc("remove_friend",
                                      params: ["friend_id": row.friendId]).execute()
        }
        await AppModel.shared.hub.sync(with: rows)
    }

    private func mutate(_ op: @escaping () async throws -> Void) async -> Bool {
        errorMessage = nil
        do {
            try await op()
            await refresh()
            return true
        } catch {
            errorMessage = Self.friendly(error)
            return false
        }
    }

    private static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("Nutzer nicht gefunden") { return "Diesen Benutzernamen gibt es nicht." }
        if text.contains("selbst hinzufügen") { return "Du kannst dich nicht selbst hinzufügen." }
        return text
    }
}
