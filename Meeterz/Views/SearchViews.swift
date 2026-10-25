import SwiftUI
import CoreLocation
import MapKit
import MapboxDirections
import MapboxNavigationCore

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
    @State private var detail: PlaceDetailItem?
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
                        PlaceRow(place: place, distance: distance(to: place), selected: false, onInfo: {
                            Task {
                                Diag.log("Details angefragt: \(place.name)")
                                if let item = await ApplePlaces.mapItem(for: place) {
                                    detail = PlaceDetailItem(mapItem: item)
                                } else {
                                    Diag.log("Keine Apple-Details gefunden: \(place.name)")
                                    app.show("Zu „\(place.name)“ hat Apple keine Details.")
                                }
                            }
                        }) { choose(place) }
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
        .presentationDragIndicator(.visible)   // zeigt, dass man das Fenster nach unten wegwischen kann
        .onAppear { focused = true }
        .task(id: query) { await search() }
        .sheet(item: $detail) { item in
            PlaceDetailSheet(item: item) { place in choose(place) }
        }
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
    @State private var current: NavigationCoordinator.Preview
    @State private var switching = false

    init(preview: NavigationCoordinator.Preview) {
        _current = State(initialValue: preview)
    }

    /// Gewählte Route: 0 = vorgeschlagene, danach Alternativen
    @State private var selected = 0
    @State private var chosen: NavigationRoutes?
    @State private var showInvite = false
    @State private var showFavoriteAlert = false
    @State private var favoriteName = ""
    /// Übernommener Ladeplan (Route führt dann über die Säulen)
    @State private var adoptedPlan: ChargePlanner.Plan?
    /// Weitere Aktionen aufgeklappt (nur E-Auto; startet immer eingeklappt)
    @State private var actionsOpen = false
    private var compactActions: Bool { EVSettings.enabled && current.mode == .car }

    #if DEBUG
    @State private var simulate = NavigationCoordinator.simulate
    #endif

    private var shown: Route { current.options[min(selected, current.options.count - 1)] }
    private var eta: Date { Date().addingTimeInterval(shown.expectedTravelTime) }

    /// Auswahl zwischen der vorgeschlagenen Route und Alternativen
    private var routeChoices: some View {
        HStack(spacing: 8) {
            ForEach(Array(current.options.enumerated()), id: \.offset) { index, route in
                Button { select(index) } label: {
                    VStack(spacing: 2) {
                        Text(index == 0 ? "Schnellste" : "Alternative \(index)")
                            .font(.caption.weight(.bold))
                        Text("\(Format.minutes(until: Date().addingTimeInterval(route.expectedTravelTime))) · \(Format.distance(route.distance))")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(index == selected ? Theme.accent : Theme.panel))
                    .foregroundStyle(index == selected ? Theme.ink : Theme.text)
                }
                .accessibilityLabel(index == 0 ? "Schnellste Route" : "Alternativroute \(index)")
            }
        }
    }

    private func select(_ index: Int) {
        selected = index
        Task {
            chosen = index == 0 ? current.routes : await current.routes.selectingAlternativeRoute(at: index - 1)
        }
    }

    /// Auto / Fahrrad / Zu Fuß – nicht auf CarPlay (dort ist klar: Auto)
    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(TravelMode.allCases) { m in
                Button { switchMode(m) } label: {
                    Label(m.title, systemImage: m.icon)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background(Capsule().fill(m == current.mode ? Theme.text : .clear))
                        .overlay(Capsule().stroke(Theme.stroke))
                        .foregroundStyle(m == current.mode ? Theme.ink : Theme.text)
                }
                .accessibilityLabel("Fortbewegungsart \(m.title)")
                .disabled(switching)
            }
        }
    }

    /// Maut / Autobahn / Fähre meiden – gilt dauerhaft und berechnet die Vorschau gleich neu
    @State private var avoidRevision = 0
    private var routeOptionsMenu: some View {
        Menu {
            ForEach(RoutePreferences.Option.allCases) { option in
                Toggle(isOn: Binding(
                    get: { _ = avoidRevision; return RoutePreferences.isOn(option) },
                    set: { RoutePreferences.set(option, $0); avoidRevision += 1; reloadForOptions() }
                )) { Label(option.title, systemImage: option.symbol) }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(RoutePreferences.active.isEmpty ? Theme.text : Theme.accent)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Theme.panel))
                .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
        }
        .id(avoidRevision)
        .disabled(switching)
        .accessibilityLabel("Routenoptionen")
    }

    private func reloadForOptions() {
        guard !switching else { return }
        switching = true
        Task {
            if let next = await app.navigation.recalculate(current, mode: current.mode) {
                current = next
                selected = 0
                chosen = nil
                adoptedPlan = nil
            }
            switching = false
        }
    }

    private func switchMode(_ m: TravelMode) {
        guard m != current.mode, !switching else { return }
        switching = true
        Task {
            if let next = await app.navigation.recalculate(current, mode: m) {
                current = next
                selected = 0
                chosen = nil
            }
            switching = false
        }
    }

    var body: some View {
        VStack(spacing: 14) {
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            if !CarPlayController.shared.isConnected { modePicker }
            RoutePreviewMap(lines: current.lines, selected: selected, destination: current.destination.coordinate)
                .id(current.mode)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    let saved = app.favorites.contains(current.destination.coordinate)
                    Button {
                        favoriteName = current.destination.name
                        showFavoriteAlert = true
                    } label: {
                        Image(systemName: saved ? "star.fill" : "star")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(saved ? Theme.accent : Theme.text)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Theme.panel))
                            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                    }
                    .disabled(saved)
                    .padding(8)
                    .accessibilityLabel(saved ? "Als Favorit gespeichert" : "Als Favorit speichern")
                }
                .overlay(alignment: .topLeading) {
                    if current.mode == .car { routeOptionsMenu.padding(8) }
                }
            if current.options.count > 1 { routeChoices }
            if current.mode == .car, let avoid = RoutePreferences.summary {
                Label("Route \(avoid)", systemImage: "slider.horizontal.3")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Ziel").font(.caption.weight(.bold)).foregroundStyle(Theme.accent).textCase(.uppercase)
                Text(current.destination.name).font(Theme.display(26))
                if let address = current.destination.address {
                    Text(address).foregroundStyle(Theme.muted)
                }
            }

            HStack(spacing: 10) {
                stat("Ankunft", Format.time.string(from: eta), highlight: true)
                stat("Dauer", Format.minutes(until: eta))
                stat("Strecke", Format.distance(shown.distance))
            }

            if current.mode == .car, EVSettings.enabled {
                ChargePlanCard(route: shown, adopted: adoptedPlan) { plan in
                    await adoptCharging(plan)
                }
            }

            Text(current.mode == .car ? "Inklusive aktueller Verkehrslage. Deine Freunde sehen deine Route, solange du teilst." : "Deine Freunde sehen deine Route, solange du teilst.")
                .font(.footnote).foregroundStyle(Theme.muted)

            #if DEBUG
            Toggle("Fahrt simulieren (Test)", isOn: $simulate)
                .onChange(of: simulate) { _, v in NavigationCoordinator.simulate = v }
                .tint(Theme.accent)
            #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .scrollIndicators(.hidden)

          // Aktionen bleiben unten sichtbar, der Rest darüber scrollt.
          // E-Auto: nur „Losfahren“ – die übrigen Knöpfe per Hochwischen am Greifer, damit der Ladeplan Platz hat.
          VStack(spacing: 10) {
            if compactActions {
                Capsule().fill(Theme.muted.opacity(0.6))
                    .frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity, minHeight: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { actionsOpen.toggle() } }
                    .accessibilityLabel(actionsOpen ? "Weitere Aktionen ausblenden" : "Weitere Aktionen")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("preview-actions-grabber")
            }
            Button("Losfahren") {
                app.navigation.start(.init(destination: current.destination, routes: chosen ?? current.routes, mode: current.mode))
            }
                .buttonStyle(PrimaryButtonStyle())
            if !compactActions || actionsOpen {
                if !app.friends.accepted.isEmpty {
                    Button { showInvite = true } label: {
                        Label("Freunde einladen", systemImage: "person.2.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
          }
          .gesture(DragGesture(minimumDistance: 12).onEnded { g in
              guard compactActions else { return }
              withAnimation(.snappy) {
                  if g.translation.height < -20 { actionsOpen = true }
                  if g.translation.height > 20 { actionsOpen = false }
              }
          })
        }
        .padding(20)
        .background(Theme.ink)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)   // zeigt, dass man das Fenster nach unten wegwischen kann
        .sheet(isPresented: $showInvite) { InviteFriendsView(place: current.destination) }
        .alert("Favorit speichern", isPresented: $showFavoriteAlert) {
            TextField("Name, z. B. Oma", text: $favoriteName)
            Button("Speichern") {
                let name = favoriteName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { app.favorites.save(kind: .other, label: name, place: current.destination) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(current.destination.address ?? "")
        }
    }

    /// Route neu über die Ladesäulen berechnen
    private func adoptCharging(_ plan: ChargePlanner.Plan) async {
        guard let routes = await app.navigation.calculate(to: current.destination, via: plan.stops.map(\.place), mode: .car) else {
            app.show("Route über die Ladesäulen konnte nicht berechnet werden.")
            return
        }
        current = .init(destination: current.destination, routes: routes, mode: .car)
        selected = 0
        chosen = nil
        adoptedPlan = plan
        ChargingSession.shared.plan = plan
        Diag.log("Ladeplan übernommen: \(plan.summary)")
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
    var selected = 0
    let destination: CLLocationCoordinate2D
    @State private var position: MapCameraPosition = .automatic
    /// Gewählte Route zuletzt zeichnen, damit sie oben liegt
    private var drawOrder: [Int] { lines.indices.filter { $0 != selected } + (lines.indices.contains(selected) ? [selected] : []) }

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            UserAnnotation()
            ForEach(drawOrder, id: \.self) { index in
                let line = lines[index]
                MapPolyline(coordinates: line)
                    .stroke(index == selected ? Color.blue : Color.gray.opacity(0.7), lineWidth: index == selected ? 6 : 4)
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
