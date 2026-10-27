import Foundation
import Observation
import Supabase

@MainActor @Observable
final class FriendsStore {
    private(set) var rows: [FriendRow] = []
    var errorMessage: String?
    /// Freunde, vor denen ich Standort und Routen verberge (Teilen pro Freund)
    private(set) var hiddenFrom: Set<UUID> = []

    var accepted: [FriendRow] { rows.filter(\.isAccepted) }
    var incoming: [FriendRow] { rows.filter { !$0.isAccepted && $0.incoming } }
    var outgoing: [FriendRow] { rows.filter { !$0.isAccepted && !$0.incoming } }

    private var client: SupabaseClient { Backend.client }

    func refresh() async {
        do {
            rows = try await client.rpc("my_friends").execute().value
            if let hidden: [UUID] = try? await client.rpc("my_hidden_friends").execute().value {
                hiddenFrom = Set(hidden)
            }
            // Siri kennt die Namen der Freunde („Navigiere mit Meeterz zu Lisa“)
            MeeterzShortcuts.updateAppShortcutParameters()
            errorMessage = nil   // vorher blieb ein einmaliger Fehler (z. B. kurz offline) für immer stehen
        } catch where AuthStore.isOffline(error) {
            // Kurz kein Netz: letzten Stand behalten, beim nächsten Aktualisieren klappt es wieder – keine Meldung
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isHidden(_ friendId: UUID) -> Bool { hiddenFrom.contains(friendId) }

    /// Standort und Routen vor einem Freund verbergen bzw. wieder zeigen
    func setHidden(_ friendId: UUID, _ hidden: Bool) async {
        struct Params: Encodable { let friend_id: UUID; let hidden: Bool }
        do {
            try await client.rpc("set_hidden_from", params: Params(friend_id: friendId, hidden: hidden)).execute()
            if hidden { hiddenFrom.insert(friendId) } else { hiddenFrom.remove(friendId) }
            if hidden, let me = AppModel.shared.profile?.id {
                // Sofort von seiner Karte nehmen (er bekommt danach keine Positionen mehr)
                await AppModel.shared.hub.announceGone(userId: me)
            }
            AppModel.shared.show(hidden ? String(localized: "Dein Standort ist für diesen Freund verborgen.") : String(localized: "Dein Standort ist wieder sichtbar."), isError: false)
        } catch {
            AppModel.shared.show(String(localized: "Das hat nicht geklappt – ist die Datenbank-Änderung eingespielt?"))
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
        if text.contains("Nutzer nicht gefunden") { return String(localized: "Diesen Benutzernamen gibt es nicht.") }
        if text.contains("selbst hinzufügen") { return String(localized: "Du kannst dich nicht selbst hinzufügen.") }
        return text
    }
}
