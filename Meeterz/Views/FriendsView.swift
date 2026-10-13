import SwiftUI

struct FriendsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var newHandle = ""
    @State private var sharingMode = SharingMode.current
    @State private var confirmDelete = false
    @AppStorage("carplay.satellite") private var carPlaySatellite = true
    #if DEBUG
    @State private var simulate = NavigationCoordinator.simulate
    #endif

    private var friends: FriendsStore { app.friends }

    var body: some View {
        NavigationStack {
            List {
                addSection
                if !friends.incoming.isEmpty { incomingSection }
                friendsSection
                if !friends.outgoing.isEmpty { outgoingSection }
                sharingSection
                appSection
                accountSection

                if let msg = friends.errorMessage ?? app.auth.errorMessage {
                    Text(msg).foregroundStyle(Theme.danger).font(.footnote)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Freunde")
            .toolbar { Button("Fertig") { dismiss() } }
            .refreshable { await app.refreshSocial() }
            .confirmationDialog(
                "Konto wirklich löschen?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Konto und alle Daten löschen", role: .destructive) {
                    Task {
                        dismiss()
                        await app.deleteAccount()
                    }
                }
            } message: {
                Text("Profil, Freundschaften, Standorte, Routen und Treffen werden endgültig gelöscht.")
            }
        }
    }

    // MARK: Abschnitte

    private var addSection: some View {
        Section {
            HStack {
                TextField("@benutzername", text: $newHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Hinzufügen") {
                    Task {
                        let handle = newHandle.replacingOccurrences(of: "@", with: "")
                        if await friends.sendRequest(handle: handle) { newHandle = "" }
                    }
                }
                .disabled(newHandle.replacingOccurrences(of: "@", with: "").count < 3)
            }
        } header: {
            Text("Freund hinzufügen")
        } footer: {
            if let profile = app.profile { Text("Dein Benutzername: @\(profile.handle)") }
        }
        .listRowBackground(Theme.panel)
    }

    private var incomingSection: some View {
        Section("Anfragen") {
            ForEach(friends.incoming) { row in
                HStack {
                    FriendLabel(row: row)
                    Spacer()
                    Button { Task { await friends.respond(to: row, accept: false) } } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Ablehnen")
                    Button("Annehmen") { Task { await friends.respond(to: row, accept: true) } }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .listRowBackground(Theme.panel)
    }

    private var friendsSection: some View {
        Section("Deine Freunde") {
            if friends.accepted.isEmpty {
                Text("Noch keine Freunde – füge jemanden über den Benutzernamen hinzu.")
                    .foregroundStyle(Theme.muted)
            }
            ForEach(friends.accepted) { row in
                HStack {
                    FriendLabel(row: row)
                    Spacer()
                    Text(status(for: row)).font(.footnote).foregroundStyle(Theme.muted)
                }
                .swipeActions {
                    Button("Entfernen", role: .destructive) { Task { await friends.remove(row) } }
                }
            }
        }
        .listRowBackground(Theme.panel)
    }

    private var outgoingSection: some View {
        Section("Gesendet") {
            ForEach(friends.outgoing) { row in
                FriendLabel(row: row)
                    .swipeActions {
                        Button("Zurückziehen", role: .destructive) { Task { await friends.remove(row) } }
                    }
            }
        }
        .listRowBackground(Theme.panel)
    }

    private var sharingSection: some View {
        Section {
            Toggle("Standort teilen", isOn: Binding(
                get: { app.profile?.isSharingNow ?? false },
                set: { on in Task { await applySharing(on: on) } }
            ))
            .tint(Theme.accent)

            Picker("Dauer", selection: $sharingMode) {
                ForEach(SharingMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: sharingMode) { _, mode in
                SharingMode.current = mode
                Task { await applySharing(on: true) }
            }

            if !app.location.canShareInBackground {
                Button("Auch im Hintergrund teilen") { app.location.requestAlways() }
            }
        } header: {
            Text("Teilen")
        } footer: {
            Text(sharingFooter)
        }
        .listRowBackground(Theme.panel)
    }

    private var appSection: some View {
        Section("App") {
            Picker("Karte in CarPlay", selection: $carPlaySatellite) {
                Text("Satellit").tag(true)
                Text("Klassisch").tag(false)
            }
            #if DEBUG
            Toggle("Fahrten simulieren (Test)", isOn: $simulate)
                .tint(Theme.accent)
                .onChange(of: simulate) { _, v in NavigationCoordinator.simulate = v }
            #endif
            Link("Datenschutzerklärung", destination: Legal.privacyURL)
        }
        .listRowBackground(Theme.panel)
    }

    private var accountSection: some View {
        Section("Konto") {
            Button("Abmelden") {
                Task {
                    dismiss()
                    await app.signOut()
                }
            }
            Button("Konto löschen", role: .destructive) { confirmDelete = true }
        }
        .listRowBackground(Theme.panel)
    }

    // MARK: Logik

    private func applySharing(on: Bool) async {
        guard on else {
            await app.auth.setSharing(false)
            return
        }
        switch sharingMode {
        case .always:
            await app.auth.setSharing(true, until: nil)
        case .oneHour:
            await app.auth.setSharing(true, until: Date().addingTimeInterval(3600))
        case .untilArrival:
            let until = app.navigation.eta.map { $0.addingTimeInterval(15 * 60) }
            await app.auth.setSharing(true, until: until)
        }
    }

    private var sharingFooter: String {
        switch sharingMode {
        case .always: "Freunde sehen dich, bis du das Teilen pausierst."
        case .oneHour: "Das Teilen endet automatisch nach einer Stunde."
        case .untilArrival: "Das Teilen endet 15 Minuten nach der Ankunft deiner nächsten Fahrt."
        }
    }

    private func status(for row: FriendRow) -> String {
        if app.routes.friendRoutes[row.friendId] != nil { return "unterwegs" }
        if let pos = app.hub.positions[row.friendId] { return Format.age(pos.age) }
        return "teilt nicht"
    }
}

private struct FriendLabel: View {
    let row: FriendRow

    var body: some View {
        HStack(spacing: 12) {
            Avatar(initials: row.initials, color: FriendPalette.color(for: row.friendId), size: 36)
            VStack(alignment: .leading) {
                Text(row.displayName).font(Theme.title(15))
                Text("@\(row.handle)").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}
