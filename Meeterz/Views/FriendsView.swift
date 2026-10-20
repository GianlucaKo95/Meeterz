import SwiftUI
import PhotosUI
import AVFoundation

struct FriendsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var newHandle = ""
    @State private var sharingMode = SharingMode.current
    @State private var confirmDelete = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var cropItem: AvatarCropItem?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var inviteFriend: FriendRow?
    @State private var invite: InviteTarget?

    private struct InviteTarget: Identifiable {
        let id = UUID()
        let place: Place
        let friendId: UUID
    }
    @AppStorage("carplay.satellite") private var carPlaySatellite = true
    #if DEBUG
    @State private var simulate = NavigationCoordinator.simulate
    #endif

    private var friends: FriendsStore { app.friends }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                addSection
                if !friends.incoming.isEmpty { incomingSection }
                friendsSection
                if !friends.outgoing.isEmpty { outgoingSection }
                sharingSection
                soundSection
                appSection
                accountSection

                if let msg = friends.errorMessage ?? app.auth.errorMessage {
                    Text(msg).foregroundStyle(Theme.danger).font(.footnote)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Profil")
            .toolbar { Button("Fertig") { dismiss() } }
            .refreshable { await app.refreshSocial() }
            .sheet(item: $inviteFriend) { friend in
                SearchView { place in
                    // erst das Such-Sheet schließen lassen, dann die Einladung öffnen
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        invite = InviteTarget(place: place, friendId: friend.friendId)
                    }
                }
            }
            .sheet(item: $invite) { target in
                InviteFriendsView(place: target.place, preselected: target.friendId)
            }
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

    private var profileSection: some View {
        let hasPhoto = (app.profile?.avatarVersion ?? 0) > 0
        return Section {
            HStack(spacing: 16) {
                Avatar(initials: myInitials, color: Theme.accent, size: 64, userId: app.profile?.id)
                VStack(alignment: .leading, spacing: 10) {
                    Menu(hasPhoto ? "Foto ändern" : "Foto hinzufügen") {
                        if CameraPicker.isAvailable {
                            Button("Foto aufnehmen", systemImage: "camera") { showCamera = true }
                        }
                        Button("Aus Mediathek wählen", systemImage: "photo.on.rectangle") { showLibrary = true }
                    }
                    if hasPhoto {
                        Button("Foto entfernen", role: .destructive) { Task { await removePhoto() } }
                    }
                }
                Spacer()
                if app.avatars.isBusy { ProgressView() }
            }
            .photosPicker(isPresented: $showLibrary, selection: $pickedPhoto, matching: .images)
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task { await applyPhoto(item) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    // erst die Kamera schließen lassen, dann den Zuschnitt öffnen
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        cropItem = AvatarCropItem(image: image)
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $cropItem) { item in
                AvatarCropView(image: item.image) { cropped in Task { await save(cropped) } }
            }
        } header: {
            Text("Profilbild")
        } footer: {
            Text("Dein Foto sehen nur Freunde, deren Anfrage du angenommen hast. Ohne Foto erscheinen deine Initialen.")
        }
        .listRowBackground(Theme.panel)
    }

    private var myInitials: String {
        (app.profile?.displayName ?? "").split(separator: " ").prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func applyPhoto(_ item: PhotosPickerItem) async {
        defer { pickedPhoto = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            app.show("Das Foto konnte nicht geladen werden.")
            return
        }
        cropItem = AvatarCropItem(image: image)
    }

    private func save(_ image: UIImage) async {
        guard let id = app.profile?.id else { return }
        if let version = await app.avatars.setMine(image, userId: id) {
            app.auth.updateAvatarVersion(version)
        }
    }

    private func removePhoto() async {
        guard let id = app.profile?.id else { return }
        if await app.avatars.removeMine(userId: id) {
            app.auth.updateAvatarVersion(0)
        }
    }

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
                    Button("Einladen") { inviteFriend = row }
                        .tint(Theme.accent)
                }
                .contextMenu {
                    Button("Zu einem Ort einladen", systemImage: "mappin.and.ellipse") { inviteFriend = row }
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

            Toggle("Meine Routen für Freunde verbergen", isOn: Binding(
                get: { app.profile?.routesHidden ?? false },
                set: { on in Task { await app.setHideRoutes(on) } }
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
                Button(app.location.alwaysAskedBefore ? "Standort-Einstellung öffnen („Immer“ wählen)" : "Auch im Hintergrund teilen") {
                    app.location.requestAlways()
                }
            }
        } header: {
            Text("Teilen")
        } footer: {
            Text(sharingFooter)
        }
        .listRowBackground(Theme.panel)
    }

    // MARK: Sound-Pack

    private var soundSection: some View {
        let sounds = app.sounds
        let me = app.profile?.id
        return Section {
            Toggle("Stimmen von Freunden abspielen", isOn: Binding(get: { sounds.enabled }, set: { sounds.enabled = $0 }))
                .tint(Theme.accent)

            ForEach(SoundMoment.allCases) { moment in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(moment.title)
                        Text(moment.example).font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if let me {
                        if sounds.isRecording && sounds.recordingMoment == moment {
                            Button { Task { await sounds.stopRecording() } } label: {
                                Label("Stopp", systemImage: "stop.circle.fill").foregroundStyle(Theme.danger)
                            }
                            .buttonStyle(.borderless)
                        } else {
                            if sounds.hasClip(me, moment) {
                                Button { Task { await sounds.preview(user: me, moment) } } label: {
                                    Image(systemName: "play.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Abspielen: \(moment.title)")
                            }
                            Button { Task { await sounds.startRecording(moment) } } label: {
                                Image(systemName: "mic.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(sounds.isRecording || sounds.isBusy)
                            .accessibilityLabel("Aufnehmen: \(moment.title)")
                        }
                    }
                }
                .swipeActions {
                    if let me, sounds.hasClip(me, moment) {
                        Button("Löschen", role: .destructive) { Task { await sounds.removeMine(moment, userId: me) } }
                    }
                }
            }

            if !friends.accepted.isEmpty {
                ForEach(friends.accepted) { f in
                    Toggle(isOn: Binding(get: { !sounds.isMuted(f.friendId) }, set: { sounds.setMuted(f.friendId, !$0) })) {
                        Text("\(f.displayName) abspielen")
                    }
                    .tint(Theme.accent)
                }
            }
        } header: {
            Text("Sound-Pack")
        } footer: {
            Text("Nimm bis zu 5 Sekunden auf. Nur Freunde, deren Anfrage du angenommen hast, hören sie – zum passenden Moment, auch im Auto. Ohne Aufnahme sagt Apples Stimme Bescheid.")
        }
        .listRowBackground(Theme.panel)
    }

    /// Installierte Version, z. B. „1.0 (7)“ – die Zahl in Klammern steigt mit jedem TestFlight-Build
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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
            NavigationLink("Navigationsstimme") { VoicePickerView() }
            Link("Datenschutzerklärung", destination: Legal.privacyURL)
            LabeledContent("Version", value: Self.versionText)
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
        let routes = " Mit „Routen verbergen“ sehen Freunde nie, wohin du fährst."
        return sharingBase + routes
    }

    private var sharingBase: String {
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
            Avatar(initials: row.initials, color: FriendPalette.color(for: row.friendId), size: 36, userId: row.friendId)
            VStack(alignment: .leading) {
                Text(row.displayName).font(Theme.title(15))
                Text("@\(row.handle)").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - Navigationsstimme

/// Auswahl der Stimme für die Sprachansagen mit Hörprobe.
struct VoicePickerView: View {
    @AppStorage(VoiceCatalog.key) private var selectedId = ""
    @State private var voices = VoiceCatalog.germanVoices

    var body: some View {
        List {
            Section {
                row(title: "Automatisch", detail: VoiceCatalog.best.map { "\($0.name) · \(VoiceCatalog.label(for: $0.quality))" } ?? "Systemstimme",
                    selected: selectedId.isEmpty) {
                    selectedId = ""
                    VoicePreview.shared.play(VoiceCatalog.best)
                }
            } footer: {
                Text("Nimmt immer die beste auf dem iPhone installierte deutsche Stimme.")
            }
            .listRowBackground(Theme.panel)

            Section("Deutsche Stimmen") {
                ForEach(voices, id: \.identifier) { voice in
                    row(title: voice.name, detail: VoiceCatalog.label(for: voice.quality), selected: selectedId == voice.identifier) {
                        selectedId = voice.identifier
                        VoicePreview.shared.play(voice)
                    }
                }
            }
            .listRowBackground(Theme.panel)

            if !VoiceCatalog.hasBetterThanDefault {
                Section {
                    Text("Es ist nur die einfache Standardstimme installiert. Eine natürlichere Stimme lädst du unter Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen → Deutsch (Premium oder Erweitert). Danach erscheint sie hier.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    Button("Einstellungen öffnen") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: {
                    Text("Bessere Stimme laden")
                }
                .listRowBackground(Theme.panel)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .navigationTitle("Navigationsstimme")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { voices = VoiceCatalog.germanVoices }   // nach dem Laden einer Stimme aktualisieren
    }

    private func row(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.text)
                    Text(detail).font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
    }
}
