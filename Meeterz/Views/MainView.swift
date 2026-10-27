import SwiftUI
import MapboxMaps
import CoreLocation

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    /// Kartenart wie in CarPlay: „satellite“ (Mapbox-Luftbild), „classic“ (Mapbox-Karte), „flyover“ (Apple, experimentell)
    @AppStorage("map.style") private var mapStyleKey = "satellite"
    private var flyover: Bool { mapStyleKey == "flyover" }
    private func setMapStyle(_ key: String) {
        MapPreferences.setStyle(MapPreferences.Style(rawValue: key) ?? .satellite)   // gilt auch in CarPlay
    }
    @AppStorage("map.3d") private var threeD = true

    @State private var viewport: Viewport = .idle
    @State private var showFriends = false
    /// „Unterwegs“-Fenster (öffnet über das Freunde-Symbol) und Folgeaktion nach dem Schließen
    @State private var showUnterwegs = false
    @State private var openManageAfterDismiss = false
    @State private var showSearch = false
    @State private var plannedMeetup: MeetupCandidate?
    @State private var recenterTick = 0
    @State private var showIncognito = false
    /// Zoomstufen über die Plus/Minus-Knöpfe (0 = Standard)
    @State private var zoomSteps = 0
    /// Ein Tipp auf die Karte blendet alle Bedienelemente aus, der nächste Tipp holt sie zurück
    @State private var chromeHidden = false
    /// Per langem Druck auf die Karte gesetzter Pin
    @State private var droppedPin: Place?
    @State private var idleToken = 0
    @Environment(\.scenePhase) private var scenePhase

    /// Kamera folgt dem eigenen Standort – in 3D schräg von hinten, in Fahrtrichtung gedreht
    private var followViewport: Viewport {
        threeD
            ? .followPuck(zoom: 16.5 + Double(zoomSteps), bearing: .course, pitch: 60)
            : .followPuck(zoom: 13 + Double(zoomSteps))
    }

    var body: some View {
        @Bindable var navigation = app.navigation

        ZStack(alignment: .top) {
            if flyover {
                // Flyover (experimentell): Apples fotorealistische 3D-Städte
                FlyoverMapView(plannedMeetup: $plannedMeetup, droppedPin: $droppedPin, onLongPress: dropPin, threeD: threeD, recenterTick: recenterTick, zoomSteps: zoomSteps)
                    .simultaneousGesture(TapGesture().onEnded { toggleChrome() })
            } else {
                map
            }

            VStack(spacing: 10) {
                topBar
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        SharingPill { showIncognito = true }
                        BackgroundHint()
                    }
                    Spacer()
                    mapControls
                }
                if let banner = app.banner {
                    BannerView(banner: banner) { app.dismissBanner() }
                }
                if ChargingSession.shared.active, !ChargingSession.shared.hiddenOnPhone {
                    ChargingCard()
                }
            }
            .padding(.horizontal, 16)
            .chromeVisibility(hidden: chromeHidden)

            VStack(spacing: 10) {
                Spacer()
                if let pin = droppedPin {
                    PinCard(pin: pin) {
                        droppedPin = nil
                        Task { await app.navigation.planRoute(to: pin) }
                    } onRemove: { droppedPin = nil }
                }
                SocialCards(plannedMeetup: $plannedMeetup)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .chromeVisibility(hidden: chromeHidden)
        }
        // Neue Hinweise oder Karten sollen nie unsichtbar bleiben
        .onChange(of: app.banner) { _, new in if new != nil { setChrome(hidden: false) } }
        .onChange(of: plannedMeetup?.id) { _, new in if new != nil { setChrome(hidden: false) } }
        .onChange(of: navigation.isNavigating) { _, _ in setChrome(hidden: false) }
        .confirmationDialog("Inkognito", isPresented: $showIncognito, titleVisibility: .visible) {
            Button("15 Minuten") { Task { await app.startIncognito(for: 15 * 60) } }
            Button("1 Stunde") { Task { await app.startIncognito(for: 60 * 60) } }
            Button("3 Stunden") { Task { await app.startIncognito(for: 3 * 60 * 60) } }
            Button("Bis ich es ausschalte") { Task { await app.startIncognito(for: nil) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Freunde sehen weder deinen Standort noch deine Route – und erfahren nicht, dass du inkognito bist.")
        }
        .sheet(isPresented: $showUnterwegs, onDismiss: {
            // Erst nach dem Schließen öffnen – ein Sheet auf ein noch schließendes Sheet schlägt fehl
            if openManageAfterDismiss { openManageAfterDismiss = false; showFriends = true }
        }) {
            UnterwegsSheet {
                openManageAfterDismiss = true
                showUnterwegs = false
            }
            .environment(app)
        }
        .sheet(isPresented: Binding(get: { app.selectedFriend != nil }, set: { if !$0 { app.selectedFriend = nil } })) {
            if let id = app.selectedFriend { FriendActionSheet(friendId: id).environment(app) }
        }
        .sheet(isPresented: $showFriends) { FriendsView() }
        .sheet(isPresented: $showSearch) { SearchView() }
        .sheet(item: $plannedMeetup) { MeetupPlannerView(candidate: $0) }
        .sheet(item: $navigation.preview) { RoutePreviewView(preview: $0) }
        .overlay {
            if navigation.isCalculating {
                ProgressView(String(localized: "Route wird berechnet …"))
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            }
        }
        .task { await app.startSession() }
        .onAppear { viewport = followViewport }
        // Weggescrollt (Mapbox-Karte): nach 10 s ohne Eingabe zurück zum Standort
        .onChange(of: viewport) { _, new in
            guard !flyover, new == .idle, app.mapFocus == nil else { return }
            idleToken += 1
            let token = idleToken
            Task {
                try? await Task.sleep(for: .seconds(10))
                if token == idleToken, viewport == .idle, app.mapFocus == nil {
                    withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport }
                }
            }
        }
        .onChange(of: app.mapFocus) { _, focus in
            guard !flyover, let focus, let target = focusViewport(focus) else { return }
            withViewportAnimation(.easeOut(duration: 0.8)) { viewport = target }
        }
        .onChange(of: navigation.isNavigating) { _, active in if active { app.mapFocus = nil } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.mapFocus = nil }
            if phase == .active, !flyover { withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport } }
        }
        .onChange(of: zoomSteps) { _, _ in
            withViewportAnimation(.easeOut(duration: 0.35)) { viewport = followViewport }
        }
        .onChange(of: threeD) { _, _ in
            withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport }
        }
    }

    /// Zeigt den Freund (und seine restliche Route) im oberen Teil der Karte, damit das halbhohe Unterwegs-Fenster nichts verdeckt.
    private func focusViewport(_ focus: AppModel.MapFocus) -> Viewport? {
        guard let item = app.friendsOnMap.first(where: { $0.friend.friendId == focus.friendId }) else { return nil }
        let friend = item.position.coordinate
        if focus.showRoute, let route = app.routes.friendRoutes[focus.friendId], route.coordinates.count > 1 {
            return .overview(
                geometry: MultiPoint(route.coordinates + [friend]),
                bearing: 0, pitch: 0,
                geometryPadding: EdgeInsets(top: 170, leading: 50, bottom: 230, trailing: 50))
        }
        // Fenster ist geschlossen: Freund genau in die Bildmitte
        let zoom = 15.5
        let center = friend
        return .camera(center: center, zoom: zoom, bearing: 0, pitch: 0)
    }

    // MARK: Karte

    private var map: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: threeD ? .course : .heading)

            // 3D-Landschaft: Höhenmodell, leicht überhöht damit Hügel sichtbar werden
            if threeD {
                RasterDemSource(id: "mapbox-dem")
                    .url("mapbox://mapbox.mapbox-terrain-dem-v1")
                    .maxzoom(14)
                Terrain(sourceId: "mapbox-dem")
                    .exaggeration(1.3)
            }

            // Routen der Freunde: dunkle Umrandung, darüber knallige Farbe (die gezeigte Route etwas breiter)
            ForEvery(Array(app.routes.friendRoutes.values)) { route in
                PolylineAnnotation(id: "routecase-\(route.friendId)", lineCoordinates: route.coordinates)
                    .lineColor(FriendPalette.routeCasing)
                    .lineWidth(app.mapFocus?.friendId == route.friendId ? 13 : 10)
            }
            ForEvery(Array(app.routes.friendRoutes.values)) { route in
                PolylineAnnotation(id: "route-\(route.friendId)", lineCoordinates: route.coordinates)
                    .lineColor(FriendPalette.routeUIColor(for: route.friendId))
                    .lineWidth(app.mapFocus?.friendId == route.friendId ? 8 : 6)
            }
            // Ziel der gezeigten Route
            if let focus = app.mapFocus, focus.showRoute, let route = app.routes.friendRoutes[focus.friendId] {
                MapViewAnnotation(coordinate: route.destination) {
                    Image(systemName: "flag.checkered.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.black, FriendPalette.routeColor(for: route.friendId))
                        .shadow(radius: 3)
                }
                .allowOverlap(true)
            }

            // Freunde live
            // Als Symbolebene statt View-Annotation: auch Freunde direkt neben mir bleiben sichtbar
            PointAnnotationGroup(app.friendsOnMap, id: \.id) { item in
                let stale = item.position.age > 5 * 60
                let photo = app.avatars.image(for: item.friend.friendId)
                return PointAnnotation(coordinate: item.position.coordinate)
                    .image(.init(
                        image: AvatarRenderer.image(initials: item.friend.initials,
                                                    color: FriendPalette.uiColor(for: item.friend.friendId),
                                                    faded: stale, photo: photo),
                        name: "avatar-\(item.friend.friendId)-\(stale)-\(item.friend.avatarVersion ?? 0)-\(photo != nil)"))
                    .iconAnchor(.bottom)
                    .textField("\(item.friend.displayName) · \(Format.age(item.position.age))")
                    .textMaxWidth(30)
                    .textOffset(x: 0, y: 0.6)
                    .textSize(13)
                    .textColor(StyleColor(.white))
                    .textHaloColor(StyleColor(.black))
                    .textHaloWidth(1.5)
                    .onTapGesture { app.selectedFriend = item.id }
            }
            .iconAllowOverlap(true)
            .iconIgnorePlacement(true)
            .textAllowOverlap(true)
            .textIgnorePlacement(true)

            // Mögliche Treffpunkte
            ForEvery(app.meetups.visibleCandidates) { candidate in
                MapViewAnnotation(coordinate: candidate.coordinate) {
                    Button { plannedMeetup = candidate } label: {
                        Image(systemName: "figure.2.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.ink, Theme.accent)
                            .shadow(radius: 4)
                    }
                    .accessibilityLabel("Möglicher Treffpunkt")
                }
                .allowOverlap(true)
            }

            if let pin = droppedPin {
                MapViewAnnotation(coordinate: pin.coordinate) { DroppedPinMarker() }
                    .allowOverlap(true)
            }

            // Geparktes Auto (beim Trennen von CarPlay gemerkt)
            if let spot = app.parking.spot {
                MapViewAnnotation(coordinate: spot.coordinate) {
                    ParkedCarMarker(spot: spot).environment(app)
                }
                .allowOverlap(true)
            }

            // Vereinbarte Treffen
            ForEvery(app.meetups.accepted) { meetup in
                MapViewAnnotation(coordinate: meetup.coordinate) {
                    VStack(spacing: 2) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.ink, Theme.accent)
                        Text(meetup.placeName)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.panel))
                    }
                }
                .allowOverlap(true)
            }
        }
        .onMapTapGesture { _ in toggleChrome() }
        .onMapLongPressGesture { context in dropPin(at: context.coordinate) }
        .mapStyle(mapStyleKey == "classic"
                  ? .standard(lightPreset: colorScheme == .light ? .day : .night)
                  : .standardSatellite(lightPreset: colorScheme == .light ? .day : .night))
        // Kompass unter die Knopfleiste rechts, sonst liegt er hinter der oberen Leiste
        .ornamentOptions(OrnamentOptions(compass: CompassViewOptions(position: .topTrailing, margins: CGPoint(x: 20, y: 400), visibility: .adaptive)))
        .ignoresSafeArea()
    }

    /// Pin setzen und Adresse nachladen
    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        let id = "pin-\(coordinate.latitude),\(coordinate.longitude)"
        droppedPin = Place(id: id, name: String(localized: "Gesetzter Pin"), address: nil, coordinate: coordinate)
        setChrome(hidden: false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            let marks = try? await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard let mark = marks?.first, droppedPin?.id == id else { return }
            let street = [mark.thoroughfare, mark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
            let city = [mark.postalCode, mark.locality].compactMap { $0 }.joined(separator: " ")
            let name = mark.name ?? (street.isEmpty ? String(localized: "Gesetzter Pin") : street)
            let address = [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
            droppedPin = Place(id: id, name: name, address: address.isEmpty ? nil : address, coordinate: coordinate)
        }
    }

    private func toggleChrome() { setChrome(hidden: !chromeHidden) }

    private func setChrome(hidden: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = hidden }
    }

    // MARK: Bedienelemente

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showSearch = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    Text("Wohin?")
                    Spacer()
                }
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(Capsule().fill(Theme.panel))
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Ziel suchen")

            CircleIconButton(
                systemName: "person.2.fill",
                label: "Freunde",
                badge: !app.friends.incoming.isEmpty,
                activeDot: !app.routes.friendRoutes.isEmpty
            ) { showUnterwegs = true }
        }
        .padding(.top, 8)
    }

    /// Zwei Knöpfe statt vier: Kartenansicht (Stil + 3D) und Standort. Inkognito steckt in der Status-Pille.
    private var mapControls: some View {
        VStack(spacing: 8) {
            Menu {
                Section("Karte") {
                    Button { setMapStyle("satellite") } label: {
                        Label("Satellit", systemImage: mapStyleKey == "satellite" ? "checkmark" : "globe.europe.africa")
                    }
                    Button { setMapStyle("classic") } label: {
                        Label("Klassische Karte", systemImage: mapStyleKey == "classic" ? "checkmark" : "map")
                    }
                    Button { setMapStyle("flyover") } label: {
                        Label("Flyover (experimentell)", systemImage: flyover ? "checkmark" : "building.2")
                    }
                }
                Section("Ansicht") {
                    Button { MapPreferences.setThreeD(true) } label: { Label("3D", systemImage: threeD ? "checkmark" : "cube") }
                    Button { MapPreferences.setThreeD(false) } label: { Label("2D", systemImage: threeD ? "square" : "checkmark") }
                }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.panel))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel("Kartenansicht")
            .accessibilityValue("\(mapStyleKey == "classic" ? "Klassisch" : (flyover ? "Flyover" : "Satellit")), \(threeD ? "3D" : "2D")")

            CircleIconButton(systemName: "location.north.line.fill", label: "Auf meinen Standort zentrieren", tint: Theme.accent) {
                app.mapFocus = nil
                recenterTick += 1
                withViewportAnimation(.easeOut(duration: 0.5)) { viewport = followViewport }
            }
        }
    }
}

// MARK: - Freunde-Marker

struct FriendMarker: View {
    let friend: FriendRow
    let position: LivePosition

    var body: some View {
        // TimelineView sorgt dafür, dass "vor X Min." mitläuft
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let stale = position.age > 5 * 60
            VStack(spacing: 3) {
                Avatar(initials: friend.initials, color: FriendPalette.color(for: friend.friendId), size: 40, faded: stale, userId: friend.friendId)
                    .overlay(Circle().stroke(FriendPalette.color(for: friend.friendId), lineWidth: 2).padding(-2))
                Text("\(friend.displayName) · \(Format.age(position.age))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.panel))
            }
            .opacity(stale ? 0.6 : 1)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Teilen-Status

/// Hinweis, solange der Standort nur „beim Verwenden“ freigegeben ist: Freunde sehen dich sonst nur bei offener App.
struct BackgroundHint: View {
    @Environment(AppModel.self) private var app
    @AppStorage("hint.always.dismissed") private var dismissed = false

    var body: some View {
        if app.location.authorization == .authorizedWhenInUse, !dismissed {
            HStack(spacing: 8) {
                Button { app.location.requestAlways() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nur bei offener App sichtbar").font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("Tippen: Standort „Immer“ erlauben").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.muted)
                    }
                    .multilineTextAlignment(.leading)
                }
                .accessibilityLabel("Standort Immer erlauben")
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Hinweis ausblenden")
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
            .frame(maxWidth: 230, alignment: .leading)
        }
    }
}

struct SharingPill: View {
    @Environment(AppModel.self) private var app
    /// Öffnet die Auswahl der Inkognito-Dauer
    var startIncognito: () -> Void = {}

    var body: some View {
        // Minütlich neu auswerten, damit das Ende von Inkognito/Teilen von selbst sichtbar wird
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            pill(app.profile)
        }
    }

    @ViewBuilder
    private func pill(_ profile: Profile?) -> some View {
        let incognito = profile?.isIncognito ?? false
        let sharing = profile?.isSharingNow ?? false
        // Tippen öffnet die Teilen-Optionen direkt auf der Karte (Dauer, Pausieren, Inkognito beenden)
        Menu {
            if incognito {
                Button("Inkognito beenden", systemImage: "eye") { Task { await app.stopIncognito() } }
            } else {
                Button("Inkognito …", systemImage: "eye.slash") { startIncognito() }
            }
            Section("Standort teilen für") {
                ForEach(SharingMode.allCases) { mode in
                    Button {
                        Task { await app.shareLocation(for: mode) }
                    } label: {
                        if sharing && SharingMode.current == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }
            if sharing {
                Button("Teilen pausieren", systemImage: "pause.circle", role: .destructive) {
                    Task { await app.auth.setSharing(false) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if incognito {
                    Image(systemName: "eye.slash.fill").font(.system(size: 11, weight: .bold))
                } else {
                    Circle().fill(sharing ? Theme.accent : Theme.muted).frame(width: 8, height: 8)
                }
                Text(label(profile))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(incognito || sharing ? Theme.accent : Theme.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Theme.panel.opacity(0.92)))
        }
        .accessibilityIdentifier("status-pill")
        .accessibilityHint("Öffnet die Optionen zum Teilen und Inkognito")
    }

    private func label(_ profile: Profile?) -> String {
        if let profile, profile.isIncognito {
            if profile.isIncognitoIndefinitely { return String(localized: "Inkognito") }
            if let until = profile.incognitoUntil { return String(localized: "Inkognito bis \(Format.time.string(from: until))") }
        }
        guard let profile, profile.isSharingNow else { return String(localized: "Teilen pausiert") }
        if let until = profile.sharingUntil { return String(localized: "Teilst live bis \(Format.time.string(from: until))") }
        return String(localized: "Teilst live")
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Theme.danger : Theme.accent)
            Text(banner.text).font(.footnote.weight(.medium))
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.footnote.bold()) }
                .accessibilityLabel("Hinweis schließen")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panelRaised))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Unterwegs-Panel

/// „Unterwegs“: wer gerade sichtbar ist, mit Entfernung und – falls vorhanden – Ziel und Ankunft.
struct UnterwegsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let manageFriends: () -> Void
    @State private var detent: PresentationDetent = .medium
    /// Höhe des Inhalts – das Fenster wird so hoch, dass alles zu sehen ist (höchstens 85 % des Bildschirms)
    @State private var contentHeight: CGFloat = 0

    private var fitted: PresentationDetent {
        guard contentHeight > 0 else { return .medium }
        let limit = (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }.first ?? 800) * 0.85
        return .height(min(contentHeight + 64, limit))   // + Titelleiste
    }
    @State private var showGroupMeetup = false
    @State private var showMeetups = false

    /// Zugesagte und offene Treffen (Gruppen zählen einmal)
    private var meetupCount: Int {
        Set(app.meetups.meetups.filter { $0.isAccepted || $0.isPending }.map { $0.groupId ?? $0.id }).count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if meetupCount > 0 {
                        Button { showMeetups = true } label: {
                            HStack {
                                Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.accent)
                                Text(meetupCount == 1 ? "1 Treffen" : "\(meetupCount) Treffen").font(Theme.title(15))
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.muted)
                            }
                            .foregroundStyle(Theme.text)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panelRaised))
                        }
                        .accessibilityIdentifier("meetups-overview")
                    }
                    if app.friends.accepted.isEmpty {
                        Text("Noch keine Freunde. Füge jemanden über den Benutzernamen hinzu.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    } else {
                        Text("\(app.friendsOnMap.count) von \(app.friends.accepted.count) sichtbar")
                            .font(.footnote).foregroundStyle(Theme.muted)
                        ForEach(app.friendsOnMapIncludingPassengers) { item in
                            FriendRowView(item: item) { showRoute in
                                // Fenster schließen: die Karte zeigt den Freund frei in der Bildmitte
                                app.mapFocus = .init(friendId: item.friend.friendId, showRoute: showRoute)
                                dismiss()
                            }
                        }
                        if app.friendsOnMapIncludingPassengers.isEmpty {
                            Text("Gerade teilt niemand seinen Standort.")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                    if !app.friendsOnMap.isEmpty {
                        Button {
                            showGroupMeetup = true
                        } label: {
                            Label("Gruppen-Treffen planen", systemImage: "person.3.fill")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, 8)
                    }
                    Button(app.friends.accepted.isEmpty ? String(localized: "Freunde hinzufügen") : String(localized: "Freunde & Profil")) {
                        manageFriends()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(16)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: SheetContentHeight.self, value: geo.size.height)
                })
            }
            .onPreferenceChange(SheetContentHeight.self) { h in
                guard abs(h - contentHeight) > 1 else { return }
                let wasFitted = detent != .large
                contentHeight = h
                if wasFitted { detent = fitted }
            }
            .background(Theme.ink)
            .navigationTitle("Unterwegs")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showGroupMeetup) { GroupMeetupView().environment(app) }
            .sheet(isPresented: $showMeetups) { MeetupsOverviewView().environment(app) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .presentationDetents([fitted, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: fitted))
        .presentationBackground(Theme.ink)
    }
}

private struct FriendRowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: AppModel.FriendOnMap
    /// true = Route (mit Ziel) auf der Karte zeigen, false = nur den Standort
    let show: (Bool) -> Void

    var body: some View {
        let route = app.routes.friendRoutes[item.friend.friendId]
        let distance = app.location.lastLocation.map { item.position.coordinate.distance(to: $0.coordinate) }

        Menu {
            Button(route == nil ? String(localized: "Auf Karte anzeigen") : String(localized: "Route anzeigen"),
                   systemImage: route == nil ? "mappin.and.ellipse" : "point.topleft.down.to.point.bottomright.curvepath") {
                show(route != nil)
            }
            Button("Zu \(item.friend.displayName) navigieren", systemImage: "arrow.triangle.turn.up.right.diamond") {
                go(to: Place(
                    id: "friend-\(item.friend.friendId)", name: item.friend.displayName,
                    address: nil, coordinate: item.position.coordinate))
            }
            let hiddenForMe = Passengers.shared.riding.contains(item.friend.friendId)
            Button(hiddenForMe ? String(localized: "Auf meiner Karte einblenden") : String(localized: "Auf meiner Karte ausblenden"),
                   systemImage: hiddenForMe ? "eye" : "eye.slash") {
                Passengers.shared.setHiddenForMe(item.friend.friendId, !hiddenForMe)
                CarPlayController.shared.refreshFriendsAfterPassengerChange()
            }
            if let route {
                Button("Zum Ziel von \(item.friend.displayName) navigieren", systemImage: "flag.checkered") {
                    go(to: Place(
                        id: "dest-\(item.friend.friendId)", name: route.destinationName ?? String(localized: "Ziel von \(item.friend.displayName)"),
                        address: nil, coordinate: route.destination))
                }
            }
        } label: {
            HStack(spacing: 12) {
                Avatar(initials: item.friend.initials, color: FriendPalette.color(for: item.friend.friendId),
                       faded: Passengers.shared.riding.contains(item.friend.friendId), userId: item.friend.friendId)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.friend.displayName).font(Theme.title(15))
                    Text(statusText(route: route))
                        .font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if let distance {
                    Text(Format.distance(distance))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(route != nil ? Theme.accent : Theme.muted)
                }
            }
            .foregroundStyle(Theme.text)
        }
    }

    /// „Unterwegs“-Fenster sofort schließen, dann die Route planen – die Vorschau kann erst nach dem Schließen erscheinen.
    private func go(to place: Place) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await app.navigation.planRoute(to: place)
        }
    }

    private func statusText(route: FriendRoute?) -> String {
        if Passengers.shared.riding.contains(item.friend.friendId) { return String(localized: "Auf deiner Karte ausgeblendet") }
        if let route {
            let dest = route.destinationName.map { String(localized: "Nach \($0)") } ?? String(localized: "Unterwegs")
            return String(localized: "\(dest) · an \(Format.time.string(from: route.eta))")
        }
        return item.position.age < 60 ? String(localized: "Live") : String(localized: "Zuletzt \(Format.age(item.position.age))")
    }
}

private extension View {
    /// Blendet Bedienelemente aus: unsichtbar, nicht antippbar, für VoiceOver und Tests nicht vorhanden.
    func chromeVisibility(hidden: Bool) -> some View {
        self.opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}


struct DroppedPinMarker: View {
    var body: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.system(size: 38))
            .foregroundStyle(.white, Theme.danger)
            .shadow(radius: 4)
            .accessibilityLabel("Gesetzter Pin")
    }
}

/// Karte unten: Navigation zum gesetzten Pin oder Pin entfernen
struct PinCard: View {
    let pin: Place
    let onNavigate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.name).font(.headline)
                if let address = pin.address { Text(address).font(.footnote).foregroundStyle(Theme.muted) }
            }
            HStack(spacing: 10) {
                Button("Entfernen", action: onRemove).buttonStyle(SecondaryButtonStyle())
                Button("Hierhin navigieren", action: onNavigate).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke, lineWidth: 1))
    }
}


/// Höhe des Inhalts im Unterwegs-Fenster
private struct SheetContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
