import SwiftUI
import CoreLocation

/// Gruppen-Treffen: Freunde wählen → Meeterz schlägt Orte vor, die für alle ähnlich weit sind → alle einladen.
struct GroupMeetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID> = []
    @State private var modes: [UUID: TravelMode] = [:]
    @State private var options: [FairMeetupFinder.Option] = []
    @State private var people: [FairMeetupFinder.Participant] = []
    @State private var searching = false
    @State private var error: String?
    @State private var sending: String?

    private static let maxFriends = 10

    private var myId: UUID { app.profile?.id ?? UUID() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if app.friendsOnMap.isEmpty {
                        Text("Gerade teilt niemand seinen Standort. Für einen fairen Treffpunkt braucht Meeterz die Standorte.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    ForEach(app.friendsOnMap) { item in
                        friendRow(item)
                    }
                } header: {
                    Text("Wer kommt mit?")
                } footer: {
                    Text("Die Fortbewegungsart kannst du je Person ändern – zu Fuß oder mit dem Rad kommen nur Orte ohne Autobahn infrage.")
                }
                .listRowBackground(Theme.panel)

                if !selected.isEmpty {
                    Section {
                        meRow
                        Button {
                            Task { await search() }
                        } label: {
                            HStack {
                                Spacer()
                                if searching { ProgressView().tint(Theme.ink) } else { Text("Fairen Treffpunkt finden") }
                                Spacer()
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .listRowBackground(Color.clear)
                        .disabled(searching)
                    }
                    .listRowBackground(Theme.panel)
                }

                if let error {
                    Section { Text(error).foregroundStyle(Theme.danger).font(.subheadline) }
                        .listRowBackground(Theme.panel)
                }

                if !options.isEmpty {
                    Section {
                        ForEach(options) { option in optionRow(option) }
                    } header: {
                        Text("Vorschläge – fair für alle")
                    } footer: {
                        Text("Sortiert nach der längsten Anfahrt: Niemand soll viel weiter fahren als die anderen.")
                    }
                    .listRowBackground(Theme.panel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Gruppen-Treffen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            }
            .onChange(of: selected) { _, _ in options = [] }
            .onChange(of: modes) { _, _ in options = [] }
        }
        .presentationBackground(Theme.ink)
    }

    // MARK: Zeilen

    private func friendRow(_ item: AppModel.FriendOnMap) -> some View {
        let id = item.friend.friendId
        let isOn = selected.contains(id)
        return HStack(spacing: 12) {
            Button {
                if isOn { selected.remove(id) } else if selected.count < Self.maxFriends { selected.insert(id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(isOn ? Theme.accent : Theme.muted)
                    Avatar(initials: item.friend.initials, color: FriendPalette.color(for: id), size: 34, userId: id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.friend.displayName).foregroundStyle(Theme.text)
                        if let me = app.location.lastLocation?.coordinate {
                            Text(Format.distance(item.position.coordinate.distance(to: me)))
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if isOn { modeMenu(for: id, default: .car) }
        }
    }

    private var meRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.fill").foregroundStyle(Theme.accent).frame(width: 24)
            Text("Du").foregroundStyle(Theme.text)
            Spacer()
            modeMenu(for: myId, default: app.navigation.travelMode)
        }
    }

    private func modeMenu(for id: UUID, default fallback: TravelMode) -> some View {
        let current = modes[id] ?? fallback
        return Menu {
            ForEach(TravelMode.allCases) { mode in
                Button(mode.title, systemImage: mode.icon) { modes[id] = mode }
            }
        } label: {
            Image(systemName: current.icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 30)
                .background(Capsule().fill(Theme.panelRaised))
        }
        .accessibilityLabel("Fortbewegung: \(current.title)")
    }

    private func optionRow(_ option: FairMeetupFinder.Option) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.place.name).font(Theme.title()).foregroundStyle(Theme.text)
                    if let address = option.place.address {
                        Text(address).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer()
                Text("max. \(Format.minutes(seconds: option.longest))")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            // Anfahrt je Person
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(people) { person in
                        if let d = option.durations[person.id] {
                            Label("\(person.name) \(Format.minutes(seconds: d))", systemImage: person.mode.icon)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Theme.panelRaised))
                                .foregroundStyle(Theme.text)
                        }
                    }
                }
            }
            Button {
                Task { await invite(option) }
            } label: {
                HStack {
                    Spacer()
                    if sending == option.id { ProgressView().tint(Theme.ink) } else { Text("Alle hierher einladen") }
                    Spacer()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(sending != nil)
        }
        .padding(.vertical, 6)
    }

    // MARK: Logik

    private func search() async {
        error = nil
        options = []
        guard let me = app.location.lastLocation?.coordinate else {
            error = String(localized: "Dein Standort ist gerade nicht bekannt.")
            return
        }
        var list = [FairMeetupFinder.Participant(id: myId, name: String(localized: "Du"), coordinate: me,
                                                 mode: modes[myId] ?? app.navigation.travelMode)]
        for item in app.friendsOnMap where selected.contains(item.friend.friendId) {
            let first = item.friend.displayName.split(separator: " ").first.map(String.init) ?? item.friend.displayName
            list.append(.init(id: item.friend.friendId, name: first, coordinate: item.position.coordinate,
                              mode: modes[item.friend.friendId] ?? .car))
        }
        people = list
        searching = true
        defer { searching = false }
        do {
            options = try await FairMeetupFinder.find(for: list)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(localized: "Suche fehlgeschlagen.")
        }
    }

    private func invite(_ option: FairMeetupFinder.Option) async {
        sending = option.id
        defer { sending = nil }
        if await app.meetups.proposeGroup(to: Array(selected), place: option.place) {
            app.show(String(localized: "\(selected.count) Freunde nach \(option.place.name) eingeladen."), isError: false)
            dismiss()
        }
    }
}
