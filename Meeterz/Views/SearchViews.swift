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
    @State private var savingToList: Place?
    @State private var openList: UUID?
    /// „In der Nähe finden“: gewählte Kategorie (statt Freitext)
    @State private var category: SearchService.Stopover?
    @State private var suggestion: RouteSuggestions.Suggestion?

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
                    if let category, query.isEmpty {
                        Button { self.category = nil; results = [] } label: {
                            Label(category.title, systemImage: "xmark.circle.fill")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(Theme.panel))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if query.isEmpty && assigning == nil && category == nil { start }
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
                                    app.show(String(localized: "Zu „\(place.name)“ hat Apple keine Details."))
                                }
                            }
                        }) { choose(place) }
                            .contextMenu {
                                Button("Als Favorit speichern", systemImage: "star") { askName(for: place) }
                                Button("In Liste speichern", systemImage: "list.bullet") { savingToList = place }
                            }
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.ink)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)   // zeigt, dass man das Fenster nach unten wegwischen kann
        // Mit Ziel-Auswahl gleich tippen; sonst wie Apple Karten erst die Vorschläge zeigen (Tastatur verdeckte sie)
        .onAppear { if onPick != nil { focused = true } }
        .task(id: query) { await search() }
        .task(id: category) { await searchCategory() }
        .task { suggestion = await RouteSuggestions.shared.refresh() }
        .task { if !app.lists.loaded { await app.lists.refresh() } }
        .sheet(item: $savingToList) { SaveToListSheet(place: $0).presentationDetents([.medium, .large]) }
        .sheet(item: Binding(get: { openList.map(ListID.init) }, set: { openList = $0?.id })) { item in
            PlaceListView(listId: item.id) { choose($0) }.presentationDetents([.medium, .large])
        }
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
        case .home: String(localized: "Adresse für „Zuhause“ suchen")
        case .work: String(localized: "Adresse für „Arbeit“ suchen")
        case .other: String(localized: "Ort für neuen Favoriten suchen")
        case nil: String(localized: "Adresse oder Ort")
        }
    }

    private func askName(for place: Place) {
        favoriteName = place.name
        namingPlace = place
    }

    private func finishAssigning() {
        focused = false   // nach dem Speichern wieder die Startseite ohne Tastatur zeigen
        namingPlace = nil
        assigning = nil
        query = ""
        results = []
    }

    // MARK: Startseite ohne Eingabe – aufgebaut wie die Suche in Apple Karten (20.11.)

    @ViewBuilder private var start: some View {
        VStack(alignment: .leading, spacing: 22) {
            suggestionsSection
            placesSection
            friendsSection
            recentsSection
            lists
            nearbySection
        }
    }

    private func header(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Theme.title(20)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Weiße bzw. dunkle Karte mit Trennlinien zwischen den Zeilen (wie Apple)
    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
    }

    /// Vorschläge: Termin bzw. übliches Ziel, vereinbarte Treffen, geparktes Auto
    @ViewBuilder private var suggestionsSection: some View {
        let meetups = app.meetups.accepted
        let parked = app.parking.spot
        if suggestion != nil || !meetups.isEmpty || parked != nil {
            VStack(alignment: .leading, spacing: 10) {
                header("Vorschläge")
                group {
                    if let suggestion {
                        suggestionRow(symbol: suggestion.isCalendar ? "calendar" : "clock.arrow.circlepath",
                                      color: .pink, title: suggestion.title, subtitle: suggestion.subtitle) { choose(suggestion.place) }
                    }
                    ForEach(meetups) { m in
                        suggestionRow(symbol: "person.2.fill", color: Theme.accent, title: m.placeName,
                                      subtitle: String(localized: "Treffen mit \(m.incoming ? m.withText : m.otherName)")) { choose(m.place) }
                    }
                    if let parked {
                        suggestionRow(symbol: "car.fill", color: .blue, title: String(localized: "Geparktes Auto"),
                                      subtitle: distance(to: parked.place).map { ActivityFormat.distance($0) } ?? "") { choose(parked.place) }
                    }
                }
            }
        }
    }

    private func suggestionRow(symbol: String, color: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Circle().fill(color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.title(16)).foregroundStyle(Theme.text).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Orte: Zuhause, Arbeit, eigene Favoriten als runde Kacheln nebeneinander, zuletzt „Hinzufügen“
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Orte")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach([Favorite.Kind.home, .work], id: \.self) { kind in
                        if let fav = (kind == .home ? app.favorites.home : app.favorites.work) {
                            favoriteTile(fav)
                        } else {
                            tile(symbol: kind == .home ? "house.fill" : "briefcase.fill", color: tileColor(kind),
                                 title: kind == .home ? String(localized: "Zuhause") : String(localized: "Arbeit"),
                                 subtitle: String(localized: "Festlegen")) { assigning = kind; focused = true }
                        }
                    }
                    ForEach(app.favorites.others) { favoriteTile($0) }
                    tile(symbol: "plus", color: Theme.panelRaised, foreground: Theme.accent,
                         title: String(localized: "Hinzufügen"), subtitle: nil) { assigning = .other; focused = true }
                }
            }
        }
    }

    private func tileColor(_ kind: Favorite.Kind) -> Color {
        switch kind {
        case .home: .cyan
        case .work: .brown
        case .other: .pink
        }
    }

    /// Entfernung unter der Kachel: „In der Nähe“ bis 200 m (wie Apple)
    private func shortDistance(_ place: Place) -> String? {
        distance(to: place).map { $0 < 200 ? String(localized: "In der Nähe") : ActivityFormat.distance($0) }
    }

    private func favoriteTile(_ fav: Favorite) -> some View {
        tile(symbol: fav.symbol, color: tileColor(fav.kind), title: fav.label, subtitle: shortDistance(fav.place)) { choose(fav.place) }
            .contextMenu {
                if fav.kind == .other {
                    Button("Umbenennen", systemImage: "pencil") { favoriteName = fav.label; renaming = fav }
                } else {
                    Button("Adresse ändern", systemImage: "pencil") { assigning = fav.kind; focused = true }
                }
                Button("Löschen", systemImage: "trash", role: .destructive) { app.favorites.remove(fav.id) }
            }
    }

    private func tile(symbol: String? = nil, initials: String? = nil, color: Color, foreground: Color = .white,
                      title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(color)
                    if let symbol { Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(foreground) }
                    if let initials { Text(initials).font(Theme.title(20)).foregroundStyle(foreground) }
                }
                .frame(width: 64, height: 64)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .minimumScaleFactor(0.8)   // „Hinzufügen“ passte sonst nicht ganz
                Text(subtitle ?? " ").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(width: 84)
        }
        .buttonStyle(.plain)
    }

    /// Freunde als runde Kacheln in ihrer Farbe – Ziel ist ihr aktueller Standort
    @ViewBuilder private var friendsSection: some View {
        let friends = app.friendsOnMap
        if !friends.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header("Freunde")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(friends, id: \.friend.friendId) { item in
                            let place = Place(id: "friend-\(item.friend.friendId)", name: item.friend.displayName,
                                              address: String(localized: "Aktueller Standort"), coordinate: item.position.coordinate)
                            tile(initials: String(item.friend.displayName.prefix(1)).uppercased(),
                                 color: FriendPalette.routeColor(for: item.friend.friendId), title: item.friend.firstName,
                                 subtitle: shortDistance(place)) { choose(place) }
                        }
                    }
                }
            }
        }
    }

    /// Zuletzt angefahrene Ziele
    @ViewBuilder private var recentsSection: some View {
        let recents = Array(app.recents.items.prefix(5))
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header("Zuletzt")
                group {
                    ForEach(recents) { r in
                        let place = Place(id: "recent-\(r.id)", name: r.name, address: r.address, coordinate: r.coordinate)
                        PlaceRow(place: place, distance: distance(to: place), selected: false, icon: "clock") { choose(place) }
                            .padding(.vertical, 6)
                            .contextMenu {
                                Button("Als Favorit speichern", systemImage: "star") { askName(for: place) }
                                Button("In Liste speichern", systemImage: "list.bullet") { savingToList = place }
                            }
                    }
                }
            }
        }
    }

    /// Eigene und von Freunden geteilte Ortslisten
    @ViewBuilder private var lists: some View {
        if !app.lists.lists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header("Listen")
                group {
                    ForEach(app.lists.lists) { list in
                        let owner = list.owner == app.lists.me ? nil : app.friend(list.owner)?.displayName
                        PlaceRow(place: Place(id: "list-\(list.id)", name: list.name,
                                              address: [owner, String(localized: "\(list.items.count) Orte")].compactMap { $0 }.joined(separator: " · "),
                                              coordinate: .init()),
                                 distance: nil, selected: false, icon: list.shared ? "person.2.fill" : "list.bullet") { openList = list.id }
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// In der Nähe finden: Kategorien, Antippen zeigt die Treffer darunter
    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("In der Nähe finden")
            group {
                ForEach(SearchService.Stopover.allCases) { kind in
                    Button { category = kind } label: {
                        HStack(spacing: 14) {
                            Image(systemName: kind.symbol).font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(nearbyColor(kind)).frame(width: 32)
                            Text(kind.title).font(Theme.title(16)).foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 13).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func nearbyColor(_ kind: SearchService.Stopover) -> Color {
        switch kind {
        case .gas: .blue
        case .charging: .green
        case .parking: .indigo
        case .food: .orange
        case .coffee: .brown
        }
    }

    private func searchCategory() async {
        guard let category, let here = app.location.lastLocation?.coordinate else { return }
        loading = true
        defer { loading = false }
        do {
            results = try await SearchService.stopovers(category, near: here, route: nil)
            errorText = results.isEmpty ? String(localized: "Nichts gefunden.") : nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func distance(to place: Place) -> Double? {
        app.location.lastLocation.map { place.coordinate.distance(to: $0.coordinate) }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { category = nil }
        guard q.count >= 3 else { if category == nil { results = []; errorText = nil }; return }
        try? await Task.sleep(for: .milliseconds(350))   // tippen abwarten
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            results = try await SearchService.search(q, near: app.location.lastLocation?.coordinate)
            errorText = results.isEmpty ? String(localized: "Nichts gefunden.") : nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func choose(_ place: Place) {
        if let kind = assigning {
            // Auswahl speichern statt navigieren
            switch kind {
            case .home: app.favorites.save(kind: .home, label: String(localized: "Zuhause"), place: place); finishAssigning()
            case .work: app.favorites.save(kind: .work, label: String(localized: "Arbeit"), place: place); finishAssigning()
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

private struct ListID: Identifiable { let id: UUID }

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
    @State private var showArriveBy = false
    @State private var showSaveToList = false
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
    /// Ladezeit des Ladeplans (E-Auto) – Ankunft und Dauer rechnen sie mit ein
    @State private var chargeTime: TimeInterval = 0
    private var charging: TimeInterval { current.mode == .car && EVSettings.enabled ? chargeTime : 0 }
    private var eta: Date { Date().addingTimeInterval(shown.expectedTravelTime + charging) }

    /// Auswahl zwischen der vorgeschlagenen Route und Alternativen
    private var routeChoices: some View {
        HStack(spacing: 8) {
            ForEach(Array(current.options.enumerated()), id: \.offset) { index, route in
                Button { select(index) } label: {
                    VStack(spacing: 2) {
                        Text(RouteVariety.label(for: index, in: current.options))
                            .font(.caption.weight(.semibold))
                        Text("\(Format.minutes(seconds: route.expectedTravelTime)) · \(ActivityFormat.distance(route.distance))")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(index == selected ? Theme.accent : Theme.panel))
                    .foregroundStyle(index == selected ? Theme.ink : Theme.text)
                }
                .accessibilityLabel(RouteVariety.label(for: index, in: current.options))
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
        VStack(spacing: 12) {
          // Karte außerhalb der Liste: Verschieben und Zoomen gehen an die Karte statt ans Scrollen (17.11.)
          if !CarPlayController.shared.isConnected { modePicker }
            RoutePreviewMap(lines: current.lines, selected: selected, destination: current.destination.coordinate,
                            onSelect: { index in if index != selected { select(index) } })
                .id(current.mode)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                  // Merken als Favorit und in einer Liste: übereinander oben rechts auf der Karte
                  VStack(spacing: 8) {
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
                    .accessibilityLabel(saved ? String(localized: "Als Favorit gespeichert") : String(localized: "Als Favorit speichern"))
                    Button { showSaveToList = true } label: {
                        Image(systemName: "bookmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Theme.panel))
                            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                    }
                    .accessibilityLabel("In Liste speichern")
                  }
                  .padding(8)
                }
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            if current.options.count > 1 { routeChoices }
            if current.mode == .car, let avoid = RoutePreferences.summary {
                Label("Route \(avoid)", systemImage: "slider.horizontal.3")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Ziel").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(current.destination.name).font(Theme.display(26))
                if let address = current.destination.address {
                    Text(address).foregroundStyle(Theme.muted)
                }
            }

            HStack(spacing: 10) {
                // Ankunft antippen = „Ankunft um …“ planen (Uhr-Symbol zeigt es an; eine eigene Zeile lag unter dem sichtbaren Bereich)
                if current.mode == .car {
                    Button { showArriveBy = true } label: {
                        stat(charging > 0 ? String(localized: "Ankunft inkl. Laden") : String(localized: "Ankunft"), ActivityFormat.time(eta), highlight: true, symbol: "clock")
                    }
                    .accessibilityIdentifier("arrive-by")
                    .accessibilityHint(Text("Ankunft um …"))
                } else {
                    stat(charging > 0 ? String(localized: "Ankunft inkl. Laden") : String(localized: "Ankunft"), ActivityFormat.time(eta), highlight: true)
                }
                stat(String(localized: "Dauer"), Format.minutes(seconds: eta.timeIntervalSinceNow))
                stat(String(localized: "Strecke"), ActivityFormat.distance(shown.distance))
            }


            if current.mode == .car, EVSettings.enabled {
                ChargePlanCard(route: shown, adopted: adoptedPlan, adopt: { plan in
                    await adoptCharging(plan)
                }, onPlan: { plan in chargeTime = plan.map { $0.direct ? 0 : $0.totalChargeTime } ?? 0 })
            }

            Text(current.mode == .car ? String(localized: "Inklusive aktueller Verkehrslage. Deine Freunde sehen deine Route, solange du teilst.") : String(localized: "Deine Freunde sehen deine Route, solange du teilst."))
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
                    .accessibilityLabel(actionsOpen ? String(localized: "Weitere Aktionen ausblenden") : String(localized: "Weitere Aktionen"))
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
        .sheet(isPresented: $showArriveBy) { ArriveBySheet(place: current.destination) }
        .sheet(isPresented: $showSaveToList) { SaveToListSheet(place: current.destination).presentationDetents([.medium, .large]) }
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
            app.show(String(localized: "Route über die Ladesäulen konnte nicht berechnet werden."))
            return
        }
        current = .init(destination: current.destination, routes: routes, mode: .car)
        selected = 0
        chosen = nil
        adoptedPlan = plan
        ChargingSession.shared.plan = plan
        Diag.log("Ladeplan übernommen: \(plan.summary)")
    }

    private func stat(_ title: String, _ value: String, highlight: Bool = false, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(Theme.muted)
                if let symbol { Image(systemName: symbol).font(.caption2.weight(.semibold)).foregroundStyle(Theme.muted) }
            }
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
    /// Wie bei Apple Karten: Antippen einer Route auf der Karte wählt sie aus
    var onSelect: ((Int) -> Void)? = nil
    @State private var position: MapCameraPosition = .automatic
    /// Gewählte Route zuletzt zeichnen, damit sie oben liegt
    private var drawOrder: [Int] { lines.indices.filter { $0 != selected } + (lines.indices.contains(selected) ? [selected] : []) }

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: [.pan, .zoom]) {
                UserAnnotation()
                ForEach(drawOrder, id: \.self) { index in
                    let line = lines[index]
                    MapPolyline(coordinates: line)
                        .stroke(index == selected ? Color.blue : Color.gray.opacity(0.7), lineWidth: index == selected ? 6 : 4)
                }
                Marker(String(localized: "Ziel"), coordinate: destination)
            }
            .mapStyle(.standard)
            .onAppear { fit() }
            // Andere Route gewählt: zurück zur Gesamtübersicht (nach eigenem Verschieben/Zoomen)
            .onChange(of: selected) { fit() }
            .onTapGesture { point in
                guard lines.count > 1, let onSelect, let index = nearestLine(to: point, proxy: proxy) else { return }
                onSelect(index)
            }
        }
    }

    /// Welche Route liegt am Tippunkt (höchstens 28 pt daneben)? Gewählte Route zuerst prüfen, sie liegt oben.
    private func nearestLine(to point: CGPoint, proxy: MapProxy) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in drawOrder.reversed() {
            let pts = lines[index].compactMap { proxy.convert($0, to: .local) }
            guard pts.count > 1 else { continue }
            var d = CGFloat.greatestFiniteMagnitude
            for i in 1..<pts.count { d = min(d, Self.distance(point, pts[i - 1], pts[i])) }
            if d < 28, d < (best?.distance ?? .greatestFiniteMagnitude) { best = (index, d) }
        }
        return best?.index
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = dx * dx + dy * dy
        guard len > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
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
