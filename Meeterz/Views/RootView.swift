import SwiftUI
import AuthenticationServices
import CryptoKit

struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.ink.ignoresSafeArea()
            switch auth.state {
            case .loading:
                ProgressView().tint(Theme.accent)
            case .signedOut:
                SignInView()
            case .needsProfile(let userId):
                OnboardingView(userId: userId)
            case .ready(let profile):
                MainView()
                    .id(profile.id)
            }
        }
        .foregroundStyle(Theme.text)
        // Standortdienst sparsam: volles GPS nur bei sichtbarer App (siehe LocationService)
        .onChange(of: scenePhase, initial: true) { _, phase in
            AppModel.shared.location.setForeground(phase != .background)
            if phase == .active {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))   // Hauptansicht erst aufbauen lassen
                    AppModel.shared.navigation.showCarPlayDriveOnPhoneIfNeeded()
                }
            }
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
            VStack(spacing: 12) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Meeterz")
                    .font(Theme.display(44))
                Text("Sieh, wo deine Freunde unterwegs sind –\nund triff sie auf dem Weg.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)
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
            .signInWithAppleButtonStyle(colorScheme == .light ? .black : .white)
            .frame(height: 54)
            .clipShape(Capsule())
            #endif

            if let msg = auth.errorMessage {
                Text(msg).foregroundStyle(Theme.danger).font(.footnote)
            }

            Link("Datenschutz", destination: Legal.privacyURL)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
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

enum Legal {
    static let privacyURL = URL(string: "https://gianlucako95.github.io/Meeterz/datenschutz")!
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
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            SecureField("Passwort (mind. 6 Zeichen)", text: $password)
                .textContentType(.password)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            HStack(spacing: 10) {
                Button("Registrieren") { submit(register: true) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Anmelden") { submit(register: false) }
                    .buttonStyle(PrimaryButtonStyle())
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
        VStack(alignment: .leading, spacing: 20) {
            Text("Wie sollen dich\ndeine Freunde sehen?")
                .font(Theme.display(30))
                .padding(.top, 40)

            VStack(alignment: .leading, spacing: 8) {
                Text("Anzeigename").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                TextField("z. B. Luca", text: $displayName)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Benutzername").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                TextField("@benutzername", text: $handle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                Text("Darüber finden dich Freunde. 3–20 Zeichen: a–z, 0–9, _")
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            if let msg = auth.errorMessage {
                Text(msg.contains("duplicate") ? "Dieser Benutzername ist schon vergeben." : msg)
                    .foregroundStyle(Theme.danger).font(.footnote)
            }

            Spacer()
            Button("Los geht's") {
                Task { await auth.createProfile(userId: userId, handle: handle, displayName: displayName) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!handleValid || displayName.isEmpty)
            .opacity(!handleValid || displayName.isEmpty ? 0.5 : 1)
        }
        .padding(24)
        .onAppear {
            if displayName.isEmpty, let name = auth.suggestedDisplayName { displayName = name }
        }
    }
}
