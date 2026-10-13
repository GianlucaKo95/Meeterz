import SwiftUI

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
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("E-Mail", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .disabled(codeSent)
                    if codeSent {
                        TextField("Code aus der E-Mail", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                    }
                } footer: {
                    Text(codeSent ? "Wir haben dir einen Code geschickt." : "Kein Passwort nötig – du bekommst einen Code per E-Mail.")
                }

                Section {
                    Button(codeSent ? "Anmelden" : "Code senden") {
                        Task {
                            busy = true
                            if codeSent {
                                _ = await auth.verify(email: email, code: code)
                            } else {
                                codeSent = await auth.sendCode(to: email)
                            }
                            busy = false
                        }
                    }
                    .disabled(busy || email.isEmpty || (codeSent && code.count < 6))

                    if codeSent {
                        Button("Andere E-Mail", role: .cancel) { codeSent = false; code = "" }
                    }
                }

                if let msg = auth.errorMessage {
                    Text(msg).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Meeterz")
        }
    }
}

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
        }
    }
}
