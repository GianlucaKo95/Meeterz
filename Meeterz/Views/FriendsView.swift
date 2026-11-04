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
    @State private var showSettings = false
    @State private var autoDelay = MessagesStore.autoDelay
    @State private var evEnabled = EVSettings.enabled
    @State private var parkingEnabled = ParkingStore.enabled
    @State private var staleHours = StaleFriends.hours
    @State private var suggestFrequent = RouteSuggestions.frequentEnabled
    @State private var suggestCalendar = RouteSuggestions.calendarEnabled && RouteSuggestions.shared.calendarAuthorized
    @State private var learnedPlaces = FrequentPlaces.shared.spots.count
    @State private var appearance = AppAppearance.current
    @State private var evRange = EVSettings.rangeKm
    @State private var evVehicle = EVSettings.vehicle
    @State private var evArrival = EVSettings.arrivalPercent
    @State private var evMinCharger = EVSettings.minAtChargerPercent

    private struct InviteTarget: Identifiable {
        let id = UUID()
        let place: Place
        let friendId: UUID
    }
    @AppStorage("map.style") private var mapStyleKey = "satellite"
    @AppStorage("map.3d") private var mapThreeD = true
    @State private var mapboxTelemetry = MapboxTelemetry.enabled
    @State private var diagText = Diag.text
    @State private var voiceOn = !MeeterzSpeechSynthesizer.shared.muted
    @AppStorage("route.avoid.tolls") private var avoidTolls = false
    @AppStorage("route.avoid.motorways") private var avoidMotorways = false
    @AppStorage("route.avoid.ferries") private var avoidFerries = false
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

                if let msg = friends.errorMessage ?? app.auth.errorMessage {
                    Text(msg).foregroundStyle(Theme.danger).font(.footnote)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle(greeting)
            .toolbar {
                // Schließen per Wischen nach unten; hier oben die Einstellungen
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Einstellungen")
                }
            }
            .navigationDestination(isPresented: $showSettings) { settingsList }
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
        }
        .presentationDragIndicator(.visible)
    }

    /// „Hallo Luca“ statt „Profil“
    private var greeting: String {
        let first = (app.profile?.displayName ?? "").split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? String(localized: "Hallo") : String(localized: "Hallo \(first)")
    }

    /// Einstellungen hinter dem Zahnrad: Teilen, Sound-Pack, App, Konto
    private var settingsList: some View {
        List {
            Section {
                NavigationLink { settingsPage("Standort teilen") { sharingSection } } label: {
                    LabeledContent {
                        Text((app.profile?.isSharingNow ?? false) ? sharingMode.title : String(localized: "Aus"))
                    } label: { Label("Standort teilen", systemImage: "location.fill") }
                }
                NavigationLink { settingsPage("Sound-Pack") { soundSection } } label: {
                    LabeledContent {
                        Text(app.sounds.enabled ? String(localized: "An") : String(localized: "Aus"))
                    } label: { Label("Sound-Pack", systemImage: "waveform") }
                }
            }
            .listRowBackground(Theme.panel)
            appSection
            accountSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            String(localized: "Konto wirklich löschen?"),
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

    // MARK: Abschnitte

    private var profileSection: some View {
        let hasPhoto = (app.profile?.avatarVersion ?? 0) > 0
        return Section {
            HStack(spacing: 16) {
                Avatar(initials: myInitials, color: Theme.accent, size: 64, userId: app.profile?.id)
                VStack(alignment: .leading, spacing: 10) {
                    Menu(hasPhoto ? String(localized: "Foto ändern") : String(localized: "Foto hinzufügen")) {
                        if CameraPicker.isAvailable {
                            Button("Foto aufnehmen", systemImage: "camera") { Task { if await Permissions.ask(.camera) { showCamera = true } } }
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
            app.show(String(localized: "Das Foto konnte nicht geladen werden."))
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
                EmptyStateView(symbol: "person.2.fill", title: "Noch keine Freunde",
                               message: "Füge jemanden oben über den Benutzernamen hinzu – oder schick eine Einladung.") {
                    ShareLink(item: InviteText.current) { Label("Einladung senden", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            ForEach(friends.accepted) { row in
                let hidden = friends.isHidden(row.friendId)
                HStack {
                    FriendLabel(row: row)
                    Spacer()
                    if hidden {
                        Image(systemName: "eye.slash").foregroundStyle(Theme.muted)
                            .accessibilityLabel("Standort verborgen")
                    }
                    Text(status(for: row)).font(.footnote).foregroundStyle(Theme.muted)
                }
                .swipeActions {
                    Button("Entfernen", role: .destructive) { Task { await friends.remove(row) } }
                    Button("Einladen") { inviteFriend = row }
                        .tint(Theme.accent)
                    Button(hidden ? String(localized: "Zeigen") : String(localized: "Verbergen")) { Task { await friends.setHidden(row.friendId, !hidden) } }
                        .tint(.gray)
                }
                .contextMenu {
                    Button("Zu einem Ort einladen", systemImage: "mappin.and.ellipse") { inviteFriend = row }
                    Button(hidden ? String(localized: "Standort wieder zeigen") : String(localized: "Standort vor \(row.displayName) verbergen"),
                           systemImage: hidden ? "eye" : "eye.slash") {
                        Task { await friends.setHidden(row.friendId, !hidden) }
                    }
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

            Toggle("Bei Verspätung automatisch Bescheid geben", isOn: Binding(
                get: { autoDelay },
                set: { autoDelay = $0; MessagesStore.autoDelay = $0 }
            ))
            .tint(Theme.accent)

            Toggle("Meine Routen für Freunde verbergen", isOn: Binding(
                get: { app.profile?.routesHidden ?? false },
                set: { on in Task { await app.setHideRoutes(on) } }
            ))
            .tint(Theme.accent)

            VStack(alignment: .leading, spacing: 8) {
                Text("Teilen für")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                Picker("Teilen für", selection: $sharingMode) {
                    ForEach(SharingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)
            .onChange(of: sharingMode) { _, mode in
                SharingMode.current = mode
                Task { await applySharing(on: true) }
            }

            if !app.location.canShareInBackground {
                Button(app.location.alwaysAskedBefore ? String(localized: "Standort-Einstellung öffnen („Immer“ wählen)") : String(localized: "Auch im Hintergrund teilen")) {
                    Task { _ = await Permissions.ask(.always) }
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

    private var liveDataSummary: String {
        if let soc = app.vehicle.liveSoc { return String(localized: "\(Int(soc.rounded())) %") }
        return app.vehicle.token == nil ? String(localized: "Aus") : String(localized: "Verbunden")
    }

    /// App-Einstellungen in Unterseiten wie bei Apple (vorher eine lange Liste in einem Abschnitt)
    private var appSection: some View {
        Section("App") {
            Picker("Darstellung", selection: Binding(
                get: { appearance },
                set: { appearance = $0; AppAppearance.current = $0 }
            )) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            NavigationLink { settingsPage("Karte & Navigation") { mapSettings } } label: {
                Label("Karte & Navigation", systemImage: "map")
            }
            NavigationLink { settingsPage("Sprachansagen") { voiceSettings } } label: {
                Label("Sprachansagen", systemImage: "speaker.wave.2")
            }
            NavigationLink { settingsPage("E-Auto") { evSettings } } label: {
                LabeledContent {
                    Text(evEnabled ? (evVehicle?.name ?? String(localized: "An")) : String(localized: "Aus"))
                } label: { Label("E-Auto", systemImage: "bolt.car") }
            }
            .accessibilityIdentifier("ev-settings")
            NavigationLink { settingsPage("Routenvorschläge") { suggestionSettings } } label: {
                Label("Routenvorschläge", systemImage: "clock.arrow.circlepath")
            }
            NavigationLink { settingsPage("Datenschutz") { privacySettings } } label: {
                Label("Datenschutz", systemImage: "hand.raised")
            }
            NavigationLink { settingsPage("Für Entwickler") { developerSettings } } label: {
                Label("Für Entwickler", systemImage: "wrench.and.screwdriver")
            }
            LabeledContent("Version", value: Self.versionText)
        }
        .listRowBackground(Theme.panel)
    }

    /// Eine Unterseite der Einstellungen im Stil der App
    private func settingsPage<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var mapSettings: some View {
        Section {
            Picker("Karte", selection: Binding<String>(
                get: { mapStyleKey },
                set: { MapPreferences.setStyle(MapPreferences.Style(rawValue: $0) ?? .satellite) }
            )) {
                ForEach(MapPreferences.Style.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("3D-Ansicht", isOn: Binding(get: { mapThreeD }, set: { MapPreferences.setThreeD($0) }))
                .tint(Theme.accent)
        } footer: {
            Text("Gilt für iPhone und CarPlay gleichermaßen und sofort, auch während der Fahrt – egal wo du umschaltest. Satellit: Luftbild mit 3D-Gebäuden. Flyover (experimentell) zeigt Apples fotorealistisches 3D-Bild, kann aber ruckeln und Route oder Pfeil leicht versetzt zeigen.")
        }
        .listRowBackground(Theme.panel)
        Section {
            Picker("Freunde ausblenden nach", selection: Binding(get: { staleHours }, set: { staleHours = $0; StaleFriends.hours = $0 })) {
                ForEach(StaleFriends.choices, id: \.self) { h in
                    Text(h == 0 ? String(localized: "Nie") : String(localized: "\(h) Std.")).tag(h)
                }
            }
        } footer: {
            Text("Freunde, von denen so lange kein neuer Standort kam, verschwinden von der Karte – statt an einem alten Ort zu stehen. Sobald sie wieder teilen, sind sie zurück.")
        }
        .listRowBackground(Theme.panel)
        Section {
            Toggle("Maut meiden", isOn: $avoidTolls).tint(Theme.accent)
            Toggle("Autobahnen meiden", isOn: $avoidMotorways).tint(Theme.accent)
            Toggle("Fähren meiden", isOn: $avoidFerries).tint(Theme.accent)
        } header: {
            Text("Routenoptionen (Auto)")
        } footer: {
            Text("Gilt für alle Routen, auch in CarPlay und für den Ladeplan. Geht ein Ziel nur mit Maut oder Fähre, nimmt Meeterz die normale Route und sagt Bescheid.")
        }
        .listRowBackground(Theme.panel)
        Section {
            Toggle("Geparktes Auto merken", isOn: Binding(get: { parkingEnabled }, set: { on in
                parkingEnabled = on
                ParkingStore.enabled = on
                if on { Task { if await Permissions.ask(.motion) { ParkingDetector.shared.start() } } }
            }))
                .tint(Theme.accent)
        }
        .listRowBackground(Theme.panel)
    }

    @ViewBuilder private var voiceSettings: some View {
        Section {
            Toggle("Sprachansagen", isOn: $voiceOn)
                .tint(Theme.accent)
                .onChange(of: voiceOn) { _, v in MeeterzSpeechSynthesizer.shared.muted = !v }
            NavigationLink("Navigationsstimme") { VoicePickerView() }
        }
        .listRowBackground(Theme.panel)
    }

    @ViewBuilder private var evSettings: some View {
        Section {
            Toggle("E-Auto", isOn: Binding(get: { evEnabled }, set: { evEnabled = $0; EVSettings.enabled = $0 }))
                .tint(Theme.accent)
            if evEnabled {
                NavigationLink {
                    VehiclePickerView(selection: $evVehicle)
                } label: {
                    LabeledContent("Fahrzeug", value: evVehicle?.fullName ?? String(localized: "Auswählen"))
                }
                .accessibilityIdentifier("ev-vehicle")
                NavigationLink {
                    VehicleLiveView()
                } label: {
                    LabeledContent("Live-Daten", value: liveDataSummary)
                }
                .accessibilityIdentifier("ev-live")
            }
        } footer: {
            if evEnabled {
                Text("Den Akkustand stellst du beim Losfahren in CarPlay unter „Mehr“ ein. Reicht er nicht bis zum Ziel, schlägt Meeterz Ladesäulen entlang der Route vor (mit 10 % Reserve).")
            }
        }
        .listRowBackground(Theme.panel)
        if evEnabled {
            Section("Ladeplanung") {
                if let vehicle = evVehicle {
                    LabeledContent("Reichweite bei 100 %", value: String(localized: "ca. \(Int(vehicle.rangeKm)) km"))
                    Stepper(value: Binding(get: { evArrival }, set: { evArrival = $0; EVSettings.arrivalPercent = $0 }),
                            in: 5...60, step: 5) {
                        LabeledContent("Ankunft mit mindestens", value: "\(Int(evArrival)) %")
                    }
                    Stepper(value: Binding(get: { evMinCharger }, set: { evMinCharger = $0; EVSettings.minAtChargerPercent = $0 }),
                            in: 5...30, step: 5) {
                        LabeledContent("An der Ladesäule mindestens", value: "\(Int(evMinCharger)) %")
                    }
                } else {
                    Stepper(value: Binding(get: { evRange }, set: { evRange = $0; EVSettings.rangeKm = $0 }),
                            in: 100...800, step: 10) {
                        LabeledContent("Reichweite bei 100 %", value: "\(Int(evRange)) km")
                    }
                }
            }
            .listRowBackground(Theme.panel)
        }
    }

    @ViewBuilder private var suggestionSettings: some View {
        Section {
            Toggle("Häufige Ziele vorschlagen", isOn: Binding(get: { suggestFrequent }, set: { on in
                suggestFrequent = on
                RouteSuggestions.frequentEnabled = on
                AppModel.shared.location.updateVisitMonitoring()
            }))
            .tint(Theme.accent)
            Toggle("Termine aus dem Kalender vorschlagen", isOn: Binding(get: { suggestCalendar }, set: { on in
                if !on { suggestCalendar = false; RouteSuggestions.calendarEnabled = false; return }
                Task { @MainActor in
                    let granted = await Permissions.ask(.calendar)
                    suggestCalendar = granted
                    RouteSuggestions.calendarEnabled = granted
                    if !granted { AppModel.shared.show(String(localized: "Kein Kalenderzugriff – in den iPhone-Einstellungen unter Meeterz erlauben.")) }
                }
            }))
            .tint(Theme.accent)
        } footer: {
            Text("Wie bei Apple Karten schlägt CarPlay beim Einsteigen ein Ziel vor: einen Termin mit Ort, zu dem du bald losfahren musst, oder einen Ort, den du um diese Zeit oft ansteuerst. Die gelernten Orte bleiben nur auf diesem iPhone.")
        }
        .listRowBackground(Theme.panel)
        if learnedPlaces > 0 {
            Section {
                Button("Gelernte Orte löschen (\(learnedPlaces))", role: .destructive) {
                    FrequentPlaces.shared.clear()
                    learnedPlaces = 0
                }
            }
            .listRowBackground(Theme.panel)
        }
    }

    @ViewBuilder private var privacySettings: some View {
        Section {
            Toggle("Mapbox beim Verbessern der Karten helfen", isOn: Binding(
                get: { mapboxTelemetry }, set: { mapboxTelemetry = $0; MapboxTelemetry.enabled = $0 }))
                .tint(Theme.accent)
        } footer: {
            Text("Sendet anonymisierte Standort- und Nutzungsdaten an Mapbox, damit Straßen, Abbiegeverbote und Verkehrsdaten besser werden. Freiwillig, standardmäßig aus.")
        }
        .listRowBackground(Theme.panel)
        Section {
            Link("Datenschutzerklärung", destination: Legal.privacyURL)
            Button("Berechtigungen in den iPhone-Einstellungen") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        .listRowBackground(Theme.panel)
    }

    @ViewBuilder private var developerSettings: some View {
        Section("Diagnose") {
            // Eingeklappt: das Protokoll ist lang – zum Senden reicht „Teilen“
            DisclosureGroup("Protokoll anzeigen") {
                Text(diagText.isEmpty ? String(localized: "Noch keine Einträge.") : diagText)
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                Button("Aktualisieren") { diagText = Diag.text }
                Spacer()
                ShareLink(item: diagText)
                Button("Leeren", role: .destructive) { Diag.clear(); diagText = "" }
            }
            .buttonStyle(.borderless)
        }
        .listRowBackground(Theme.panel)
        #if DEBUG
        Section {
            Toggle("Fahrten simulieren (Test)", isOn: $simulate)
                .tint(Theme.accent)
                .onChange(of: simulate) { _, v in NavigationCoordinator.simulate = v }
        }
        .listRowBackground(Theme.panel)
        #endif
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
        await app.shareLocation(for: sharingMode)
    }

    private var sharingFooter: String {
        let routes = String(localized: " Mit „Routen verbergen“ sehen Freunde nie, wohin du fährst.")
        return sharingBase + routes
    }

    private var sharingBase: String {
        sharingMode.explanation
    }

    private func status(for row: FriendRow) -> String {
        if app.routes.friendRoutes[row.friendId] != nil { return "unterwegs" }
        if let pos = app.hub.positions[row.friendId] { return Format.age(pos.age) }
        return String(localized: "teilt nicht")
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
    @State private var voices = VoiceCatalog.voices

    var body: some View {
        List {
            Section {
                row(title: String(localized: "Automatisch"), detail: VoiceCatalog.best.map { "\($0.name) · \(VoiceCatalog.label(for: $0.quality))" } ?? String(localized: "Systemstimme"),
                    selected: selectedId.isEmpty) {
                    selectedId = ""
                    VoicePreview.shared.play(VoiceCatalog.best)
                }
            } footer: {
                Text("Nimmt immer die beste auf dem iPhone installierte Stimme deiner Sprache.")
            }
            .listRowBackground(Theme.panel)

            Section("Stimmen") {
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
                    Text("Es ist nur die einfache Standardstimme installiert. Eine natürlichere Stimme lädst du unter Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen → deine Sprache (Premium oder Erweitert). Danach erscheint sie hier.")
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
        .onAppear { voices = VoiceCatalog.voices }   // nach dem Laden einer Stimme aktualisieren
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
