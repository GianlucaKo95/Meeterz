import SwiftUI
import CoreLocation

// MARK: - Zielsuche

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var loading = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Adresse oder Ort", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel("Eingabe löschen")
                }
            }
            .padding(.horizontal, 16).frame(height: 52)
            .background(Capsule().fill(Theme.panel))

            ScrollView {
                VStack(spacing: 8) {
                    if query.isEmpty { suggestions }
                    if loading { ProgressView().padding() }
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.muted) }
                    ForEach(results) { place in
                        PlaceRow(place: place, distance: distance(to: place), selected: false) { choose(place) }
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.ink)
        .presentationDetents([.large])
        .onAppear { focused = true }
        .task(id: query) { await search() }
    }

    /// Ohne Eingabe: Freunde und vereinbarte Treffpunkte als schnelle Ziele
    @ViewBuilder private var suggestions: some View {
        let meetupPlaces = app.meetups.accepted.map(\.place)
        let friendPlaces = app.friendsOnMap.map {
            Place(id: "friend-\($0.friend.friendId)", name: $0.friend.displayName,
                  address: "Aktueller Standort", coordinate: $0.position.coordinate)
        }
        if !meetupPlaces.isEmpty || !friendPlaces.isEmpty {
            Text("Schnellziele").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(meetupPlaces + friendPlaces) { place in
                PlaceRow(place: place, distance: distance(to: place), selected: false) { choose(place) }
            }
        }
    }

    private func distance(to place: Place) -> Double? {
        app.location.lastLocation.map { place.coordinate.distance(to: $0.coordinate) }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { results = []; errorText = nil; return }
        try? await Task.sleep(for: .milliseconds(350))   // tippen abwarten
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            results = try await SearchService.search(q, near: app.location.lastLocation?.coordinate)
            errorText = results.isEmpty ? "Nichts gefunden." : nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func choose(_ place: Place) {
        dismiss()
        Task { await app.navigation.planRoute(to: place) }
    }
}

// MARK: - Routenvorschau

struct RoutePreviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let preview: NavigationCoordinator.Preview

    #if DEBUG
    @State private var simulate = NavigationCoordinator.simulate
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ziel").font(.caption.weight(.bold)).foregroundStyle(Theme.accent).textCase(.uppercase)
                Text(preview.destination.name).font(Theme.display(26))
                if let address = preview.destination.address {
                    Text(address).foregroundStyle(Theme.muted)
                }
            }

            HStack(spacing: 10) {
                stat("Ankunft", Format.time.string(from: preview.eta), highlight: true)
                stat("Dauer", Format.minutes(until: preview.eta))
                stat("Strecke", Format.distance(preview.distance))
            }

            Text("Inklusive aktueller Verkehrslage. Deine Freunde sehen deine Route, solange du teilst.")
                .font(.footnote).foregroundStyle(Theme.muted)

            #if DEBUG
            Toggle("Fahrt simulieren (Test)", isOn: $simulate)
                .onChange(of: simulate) { _, v in NavigationCoordinator.simulate = v }
                .tint(Theme.accent)
            #endif

            Spacer()
            Button("Losfahren") { app.navigation.start(preview) }
                .buttonStyle(PrimaryButtonStyle())
            Button("Abbrechen") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(20)
        .background(Theme.ink)
        .presentationDetents([.medium, .large])
    }

    private func stat(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.muted)
            Text(value).font(Theme.display(20)).foregroundStyle(highlight ? Theme.accent : Theme.text)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelRaised))
    }
}
