import SwiftUI
import CoreLocation
import MapKit

// MARK: - Zielsuche

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Gesetzt = Ort nur auswählen (z. B. zum Einladen), statt die Route zu planen
    var onPick: ((Place) -> Void)?
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var loading = false
    @State private var errorText: String?
    @FocusState private var focused: Bool
    /// Gesetzt = die nächste Auswahl wird als Zuhause/Arbeit/Favorit gespeichert statt zur Route zu führen
    @State private var assigning: Favorite.Kind?
    @State private var namingPlace: Place?
    @State private var favoriteName = ""
    @State private var renaming: Favorite?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(assigningPrompt, text: $query)
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
                    if query.isEmpty && assigning == nil { favorites; suggestions }
                    if loading { ProgressView().padding() }
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.muted) }
                    ForEach(results) { place in
                        PlaceRow(place: place, distance: distance(to: place), selected: false) { choose(place) }
                            .contextMenu {
                                Button("Als Favorit speichern", systemImage: "star") { askName(for: place) }
                            }
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.ink)
        .presentationDetents([.large])
        .onAppear { focused = true }
        .task(id: query) { await search() }
        .alert("Favorit speichern", isPresented: Binding(get: { namingPlace != nil }, set: { if !$0 { namingPlace = nil } })) {
            TextField("Name, z. B. Oma", text: $favoriteName)
            Button("Speichern") {
                let name = favoriteName.trimmingCharacters(in: .whitespaces)
                if let place = namingPlace, !name.isEmpty { app.favorites.save(kind: .other, label: name, place: place) }
                finishAssigning()
            }
            Button("Abbrechen", role: .cancel) { finishAssigning() }
        } message: {
            Text(namingPlace?.address ?? namingPlace?.name ?? "")
        }
        .alert("Favorit umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $favoriteName)
            Button("Speichern") {
                let name = favoriteName.trimmingCharacters(in: .whitespaces)
                if let fav = renaming, !name.isEmpty { app.favorites.rename(fav.id, to: name) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var assigningPrompt: String {
        switch assigning {
        case .home: "Adresse für „Zuhause“ suchen"
        case .work: "Adresse für „Arbeit“ suchen"
        case .other: "Ort für neuen Favoriten suchen"
        case nil: "Adresse oder Ort"
        }
    }

    private func askName(for place: Place) {
        favoriteName = place.name
        namingPlace = place
    }

    private func finishAssigning() {
        namingPlace = nil
        assigning = nil
        query = ""
        results = []
    }

    /// Favoriten ganz oben: Zuhause, Arbeit (auch wenn noch leer, dann zum Festlegen) und eigene Orte
    @ViewBuilder private var favorites: some View {
        Text("Favoriten").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
        ForEach([Favorite.Kind.home, .work], id: \.self) { kind in
            if let fav = (kind == .home ? app.favorites.home : app.favorites.work) {
                favoriteRow(fav)
            } else {
                PlaceRow(
                    place: Place(id: "set-\(kind.rawValue)", name: kind == .home ? "Zuhause festlegen" : "Arbeit festlegen",
                                 address: "Adresse suchen und speichern", coordinate: .init()),
                    distance: nil, selected: false, icon: kind == .home ? "house" : "briefcase"
                ) { assigning = kind; focused = true }
            }
        }
        ForEach(app.favorites.others) { favoriteRow($0) }
        PlaceRow(
            place: Place(id: "new-favorite", name: "Favorit hinzufügen", address: "Ort suchen und mit Namen speichern", coordinate: .init()),
            distance: nil, selected: false, icon: "plus.circle"
        ) { assigning = .other; focused = true }
    }

    private func favoriteRow(_ fav: Favorite) -> some View {
        PlaceRow(place: fav.place, distance: distance(to: fav.place), selected: false, icon: fav.symbol) { choose(fav.place) }
            .contextMenu {
                if fav.kind == .other {
                    Button("Umbenennen", systemImage: "pencil") { favoriteName = fav.label; renaming = fav }
                } else {
                    Button("Adresse ändern", systemImage: "pencil") { assigning = fav.kind; focused = true }
                }
                Button("Löschen", systemImage: "trash", role: .destructive) { app.favorites.remove(fav.id) }
            }
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
        if let kind = assigning {
            // Auswahl speichern statt navigieren
            switch kind {
            case .home: app.favorites.save(kind: .home, label: "Zuhause", place: place); finishAssigning()
            case .work: app.favorites.save(kind: .work, label: "Arbeit", place: place); finishAssigning()
            case .other: askName(for: place)
            }
            return
        }
        dismiss()
        if let onPick {
            onPick(place)
        } else {
            Task { await app.navigation.planRoute(to: place) }
        }
    }
}

// MARK: - Routenvorschau

struct RoutePreviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let preview: NavigationCoordinator.Preview

    @State private var showInvite = false
    @State private var showFavoriteAlert = false
    @State private var favoriteName = ""

    #if DEBUG
    @State private var simulate = NavigationCoordinator.simulate
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoutePreviewMap(lines: preview.lines, destination: preview.destination.coordinate)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16))
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

            let saved = app.favorites.contains(preview.destination.coordinate)
            Button {
                favoriteName = preview.destination.name
                showFavoriteAlert = true
            } label: {
                Label(saved ? "Als Favorit gespeichert" : "Als Favorit speichern", systemImage: saved ? "star.fill" : "star")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(saved)

            #if DEBUG
            Toggle("Fahrt simulieren (Test)", isOn: $simulate)
                .onChange(of: simulate) { _, v in NavigationCoordinator.simulate = v }
                .tint(Theme.accent)
            #endif

            Spacer()
            Button("Losfahren") { app.navigation.start(preview) }
                .buttonStyle(PrimaryButtonStyle())
            if !app.friends.accepted.isEmpty {
                Button { showInvite = true } label: {
                    Label("Freunde einladen", systemImage: "person.2.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button("Abbrechen") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(20)
        .background(Theme.ink)
        .presentationDetents([.large])
        .sheet(isPresented: $showInvite) { InviteFriendsView(place: preview.destination) }
        .alert("Favorit speichern", isPresented: $showFavoriteAlert) {
            TextField("Name, z. B. Oma", text: $favoriteName)
            Button("Speichern") {
                let name = favoriteName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { app.favorites.save(kind: .other, label: name, place: preview.destination) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(preview.destination.address ?? "")
        }
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


/// Kleine Karte in der Routenvorschau: zeigt Route(n) komplett und zoomt passend darauf.
struct RoutePreviewMap: View {
    let lines: [[CLLocationCoordinate2D]]
    let destination: CLLocationCoordinate2D
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            ForEach(Array(lines.enumerated()).reversed(), id: \.offset) { index, line in
                MapPolyline(coordinates: line)
                    .stroke(index == 0 ? Color.blue : Color.gray.opacity(0.7), lineWidth: index == 0 ? 6 : 4)
            }
            Marker("Ziel", coordinate: destination)
        }
        .mapStyle(.standard)
        .onAppear { fit() }
    }

    private func fit() {
        let all = lines.flatMap { $0 } + [destination]
        guard let first = all.first else { return }
        var minLat = first.latitude, maxLat = first.latitude, minLng = first.longitude, maxLng = first.longitude
        for c in all {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
                                    longitudeDelta: max((maxLng - minLng) * 1.4, 0.005))
        position = .region(MKCoordinateRegion(center: center, span: span))
    }
}
