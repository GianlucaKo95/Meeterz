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

    // MARK: Login per E-Mail-Code

    func sendCode(to email: String) async -> Bool {
        await run { try await self.client.auth.signInWithOTP(email: email) }
    }

    func verify(email: String, code: String) async -> Bool {
        await run {
            try await self.client.auth.verifyOTP(email: email, token: code, type: .email)
        }
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
