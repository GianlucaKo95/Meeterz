import SwiftUI

struct FriendsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    let store: FriendsStore
    let location: LocationService

    @State private var newHandle = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Benutzername", text: $newHandle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Hinzufügen") {
                            Task {
                                if await store.sendRequest(handle: newHandle) { newHandle = "" }
                            }
                        }
                        .disabled(newHandle.count < 3)
                    }
                } header: {
                    Text("Freund hinzufügen")
                } footer: {
                    Text("Dein Benutzername: @\(profile.handle)")
                }

                if !store.incoming.isEmpty {
                    Section("Anfragen") {
                        ForEach(store.incoming) { row in
                            HStack {
                                FriendLabel(row: row)
                                Spacer()
                                Button("Annehmen") { Task { await store.respond(to: row, accept: true) } }
                                    .buttonStyle(.borderedProminent)
                                Button(role: .destructive) {
                                    Task { await store.respond(to: row, accept: false) }
                                } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Section("Freunde") {
                    if store.accepted.isEmpty {
                        Text("Noch keine Freunde – füge jemanden über den Benutzernamen hinzu.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.accepted) { row in
                        FriendLabel(row: row)
                            .swipeActions {
                                Button("Entfernen", role: .destructive) { Task { await store.remove(row) } }
                            }
                    }
                }

                if !store.outgoing.isEmpty {
                    Section("Gesendet") {
                        ForEach(store.outgoing) { row in
                            FriendLabel(row: row)
                                .swipeActions {
                                    Button("Zurückziehen", role: .destructive) { Task { await store.remove(row) } }
                                }
                        }
                    }
                }

                Section("Einstellungen") {
                    Toggle("Standort teilen", isOn: Binding(
                        get: { profile.sharingEnabled },
                        set: { v in Task { await auth.setSharing(v) } }
                    ))
                    if !location.canShareInBackground {
                        Button("Auch im Hintergrund teilen") { location.requestAlways() }
                    }
                    Button("Abmelden", role: .destructive) { Task { await auth.signOut() } }
                }

                if let msg = store.errorMessage ?? auth.errorMessage {
                    Text(msg).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Freunde")
            .toolbar { Button("Fertig") { dismiss() } }
            .refreshable { await store.refresh() }
        }
    }
}

private struct FriendLabel: View {
    let row: FriendRow
    var body: some View {
        VStack(alignment: .leading) {
            Text(row.displayName)
            Text("@\(row.handle)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
