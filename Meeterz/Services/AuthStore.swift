import Foundation
import Observation
import Supabase

@MainActor @Observable
final class AuthStore {
    enum State: Equatable {
        case loading
        case signedOut
        case needsProfile(UUID)
        case ready(Profile)
    }

    var state: State = .loading
    var errorMessage: String?

    private var client: SupabaseClient { Backend.client }

    var profile: Profile? {
        if case .ready(let p) = state { return p }
        return nil
    }

    func start() async {
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .signedOut, .userUpdated:
                await load(session: session)
            default:
                break
            }
        }
    }

    private func load(session: Session?) async {
        guard let session, !session.isExpired else {
            state = .signedOut
            return
        }
        do {
            let rows: [Profile] = try await client.from("profiles")
                .select("id, handle, display_name, sharing_enabled")
                .eq("id", value: session.user.id)
                .execute().value
            state = rows.first.map(State.ready) ?? .needsProfile(session.user.id)
        } catch {
            errorMessage = error.localizedDescription
            state = .needsProfile(session.user.id)
        }
    }

    // MARK: Mit Apple anmelden

    /// Apple liefert den Namen nur beim allerersten Login – für das Onboarding merken
    var suggestedDisplayName: String?

    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async {
        if let fullName {
            let name = PersonNameComponentsFormatter().string(from: fullName)
            if !name.isEmpty { suggestedDisplayName = name }
        }
        await run {
            try await self.client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
            )
        }
    }

    func report(_ message: String) {
        errorMessage = message
    }

    func createProfile(userId: UUID, handle: String, displayName: String) async {
        let p = Profile(id: userId,
                        handle: handle.lowercased().trimmingCharacters(in: .whitespaces),
                        displayName: displayName.trimmingCharacters(in: .whitespaces),
                        sharingEnabled: true)
        if await run({ try await self.client.from("profiles").insert(p).execute() }) {
            state = .ready(p)
        }
    }

    func setSharing(_ enabled: Bool) async {
        guard var p = profile else { return }
        let ok = await run {
            try await self.client.from("profiles")
                .update(["sharing_enabled": enabled])
                .eq("id", value: p.id)
                .execute()
        }
        if ok {
            p.sharingEnabled = enabled
            state = .ready(p)
        }
    }

    func signOut() async {
        _ = await run { try await self.client.auth.signOut() }
    }

    @discardableResult
    private func run(_ op: @escaping () async throws -> Void) async -> Bool {
        errorMessage = nil
        do {
            try await op()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
