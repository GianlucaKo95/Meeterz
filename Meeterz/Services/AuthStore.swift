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

    private var running = false

    func start() async {
        // Läuft schon (z. B. durch einen Start im Hintergrund)? Dann nicht ein zweites Mal abonnieren.
        guard !running else { return }
        running = true
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
                .select("id, handle, display_name, sharing_enabled, sharing_until, incognito_until, hide_routes, avatar_version")
                .eq("id", value: session.user.id)
                .execute().value
            state = rows.first.map(State.ready) ?? .needsProfile(session.user.id)
            errorMessage = nil
        } catch where Self.isOffline(error) {
            // Kein Netz (z. B. Start im Hintergrund, Funkloch): kein Fehlertext, der stehen bleibt, und schon gar nicht
            // „Profil anlegen“ – das Profil gibt es ja. Bisherigen Stand behalten und gleich noch einmal versuchen.
            Diag.log("Profil laden: kein Netz – neuer Versuch in 10 s")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.profile?.id != session.user.id else { return }
                await self.load(session: try? await self.client.auth.session)
            }
        } catch {
            errorMessage = error.localizedDescription
            state = .needsProfile(session.user.id)
        }
    }

    /// Netzwerkfehler (offline, Zeitüberschreitung, Verbindung verloren) – vorübergehend, kein Grund für eine Meldung
    nonisolated static func isOffline(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain { return true }
        return error is URLError
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
            WidgetSnapshotWriter.shared.update(force: true)
        }
    }

    /// Inkognito: nil = aus, sonst bis zu diesem Zeitpunkt
    func setIncognito(until: Date?) async {
        guard var p = profile else { return }
        struct Update: Encodable {
            let until: Date?
            enum CodingKeys: String, CodingKey { case until = "incognito_until" }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(until, forKey: .until)   // nil wird bewusst als null geschrieben
            }
        }
        let id = p.id
        let ok = await run {
            try await self.client.from("profiles").update(Update(until: until)).eq("id", value: id).execute()
        }
        if ok {
            p.incognitoUntil = until
            state = .ready(p)
        }
    }

    /// Eigene Routen dauerhaft für Freunde verbergen
    func setHideRoutes(_ hide: Bool) async {
        guard var p = profile else { return }
        struct Update: Encodable {
            let hide: Bool
            enum CodingKeys: String, CodingKey { case hide = "hide_routes" }
        }
        let id = p.id
        let ok = await run {
            try await self.client.from("profiles").update(Update(hide: hide)).eq("id", value: id).execute()
        }
        if ok {
            p.hideRoutes = hide
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
