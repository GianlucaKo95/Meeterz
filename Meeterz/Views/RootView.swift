import SwiftUI
import AuthenticationServices
import CryptoKit

struct RootView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            SignInView()
        case .needsProfile(let userId):
            OnboardingView(userId: userId)
        case .ready(let profile):
            MainView(profile: profile)
                .id(profile.id)
        }
    }
}

struct SignInView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.colorScheme) private var colorScheme
    /// Roh-Nonce geht an Supabase, der SHA-256-Hash an Apple – so ist das Token an diesen Login gebunden
    @State private var nonce = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Text("Meeterz")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                Text("Sieh, wo deine Freunde unterwegs sind –\nund triff sie auf dem Weg.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            #if DEV_LOGIN
            DevLoginForm()
            #else
            SignInWithAppleButton(.signIn) { request in
                nonce = Self.randomNonce()
                request.requestedScopes = [.fullName, .email]
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let tokenData = credential.identityToken,
                          let idToken = String(data: tokenData, encoding: .utf8)
                    else {
                        auth.report("Apple hat kein gültiges Token geliefert.")
                        return
                    }
                    Task {
                        await auth.signInWithApple(idToken: idToken, rawNonce: nonce, fullName: credential.fullName)
                    }
                case .failure(let error):
                    // Abbrechen durch den Nutzer ist kein Fehler
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        auth.report(error.localizedDescription)
                    }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 54)
            #endif

            if let msg = auth.errorMessage {
                Text(msg).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding(24)
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

#if DEV_LOGIN
#if !DEBUG
#error("DEV_LOGIN darf nicht in Release-Builds landen – MEETERZ_FLAGS in Config.xcconfig leeren.")
#endif

/// Test-Login für die kostenlose Apple-ID. Voraussetzung in Supabase:
/// Email-Provider an, "Confirm email" aus.
private struct DevLoginForm: View {
    @Environment(AuthStore.self) private var auth
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 12) {
            Text("TEST-LOGIN").font(.caption.bold()).foregroundStyle(.orange)
            TextField("E-Mail", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Passwort (mind. 6 Zeichen)", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Registrieren") { submit(register: true) }
                    .buttonStyle(.bordered)
                Button("Anmelden") { submit(register: false) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(busy || email.isEmpty || password.count < 6)
        }
    }

    private func submit(register: Bool) {
        Task {
            busy = true
            await auth.devSignIn(email: email, password: password, register: register)
            busy = false
        }
    }
}
#endif

struct OnboardingView: View {
    @Environment(AuthStore.self) private var auth
    let userId: UUID
    @State private var handle = ""
    @State private var displayName = ""

    private var handleValid: Bool {
        handle.lowercased().range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Anzeigename", text: $displayName)
                    TextField("Benutzername", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Über deinen Benutzernamen finden dich Freunde. 3–20 Zeichen: a–z, 0–9, _")
                }
                Button("Los geht's") {
                    Task { await auth.createProfile(userId: userId, handle: handle, displayName: displayName) }
                }
                .disabled(!handleValid || displayName.isEmpty)

                if let msg = auth.errorMessage {
                    Text(msg).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Profil anlegen")
            .onAppear {
                if displayName.isEmpty, let name = auth.suggestedDisplayName { displayName = name }
            }
        }
    }
}
