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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendRequest(handle: String) async -> Bool {
        await mutate {
            try await self.client.rpc("send_friend_request",
                                      params: ["target_handle": handle]).execute()
        }
    }

    func respond(to row: FriendRow, accept: Bool) async {
        struct Params: Encodable { let request_id: UUID; let accept: Bool }
        _ = await mutate {
            try await self.client.rpc("respond_friend_request",
                                      params: Params(request_id: row.friendshipId, accept: accept)).execute()
        }
    }

    func remove(_ row: FriendRow) async {
        _ = await mutate {
            try await self.client.rpc("remove_friend",
                                      params: ["friend_id": row.friendId]).execute()
        }
    }

    private func mutate(_ op: @escaping () async throws -> Void) async -> Bool {
        errorMessage = nil
        do {
            try await op()
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
