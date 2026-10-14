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
                .select("id, handle, display_name, sharing_enabled, sharing_until")
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

    #if DEV_LOGIN
    // MARK: Test-Login (nur Personal Team / Debug)

    func devSignIn(email: String, password: String, register: Bool) async {
        await run {
            if register {
                _ = try await self.client.auth.signUp(email: email, password: password)
            } else {
                _ = try await self.client.auth.signIn(email: email, password: password)
            }
        }
    }
    #endif

    func report(_ message: String) {
        errorMessage = message
    }

    // MARK: Profil

    func createProfile(userId: UUID, handle: String, displayName: String) async {
        let p = Profile(id: userId,
                        handle: handle.lowercased().trimmingCharacters(in: .whitespaces),
                        displayName: displayName.trimmingCharacters(in: .whitespaces),
                        sharingEnabled: true,
                        sharingUntil: nil)
        if await run({ try await self.client.from("profiles").insert(p).execute() }) {
            state = .ready(p)
        }
    }

    /// Teilen an/aus, optional mit Ablaufzeit (nil = unbegrenzt)
    func setSharing(_ enabled: Bool, until: Date? = nil) async {
        guard var p = profile else { return }
        struct Update: Encodable {
            let enabled: Bool
            let until: Date?
            enum CodingKeys: String, CodingKey {
                case enabled = "sharing_enabled"
                case until = "sharing_until"
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(enabled, forKey: .enabled)
                try c.encode(until, forKey: .until)   // nil wird bewusst als null geschrieben
            }
        }
        let id = p.id
        let ok = await run {
            try await self.client.from("profiles")
                .update(Update(enabled: enabled, until: until))
                .eq("id", value: id)
                .execute()
        }
        if ok {
            p.sharingEnabled = enabled
            p.sharingUntil = until
            state = .ready(p)
        }
    }

    func signOut() async {
        _ = await run { try await self.client.auth.signOut() }
        state = .signedOut
    }

    /// Löscht das Konto samt aller Daten (App-Store-Pflicht)
    /// Bildversion lokal übernehmen, nachdem das Profilbild hochgeladen oder entfernt wurde
    func updateAvatarVersion(_ version: Int?) {
        guard var p = profile else { return }
        p.avatarVersion = version
        state = .ready(p)
    }

    func deleteAccount() async {
        let ok = await run { try await self.client.rpc("delete_account").execute() }
        guard ok else { return }
        try? await client.auth.signOut(scope: .local)
        state = .signedOut
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
