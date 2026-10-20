import SwiftUI
import MapboxMaps
import CoreLocation

struct MainView: View {
    @Environment(AppModel.self) private var app

    @AppStorage("map.satellite") private var satellite = true
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
            if satellite {
                // Satellit: Apples Flyover (fotorealistische 3D-Gebäude)
                FlyoverMapView(plannedMeetup: $plannedMeetup, droppedPin: $droppedPin, onLongPress: dropPin, threeD: threeD, recenterTick: recenterTick, zoomSteps: zoomSteps)
                    .simultaneousGesture(TapGesture().onEnded { toggleChrome() })
            } else {
                map
            }

            VStack(spacing: 10) {
                topBar
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        SharingPill()
                        BackgroundHint()
                    }
                    Spacer()
                    mapControls
                }
                if let banner = app.banner {
                    BannerView(banner: banner) { app.dismissBanner() }
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
        .sheet(isPresented: $showFriends) { FriendsView() }
        .sheet(isPresented: $showSearch) { SearchView() }
        .sheet(item: $plannedMeetup) { MeetupPlannerView(candidate: $0) }
        .sheet(item: $navigation.preview) { RoutePreviewView(preview: $0) }
        .overlay {
            if navigation.isCalculating {
                ProgressView("Route wird berechnet …")
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            }
        }
        .task { await app.startSession() }
        .onAppear { viewport = followViewport }
        // Weggescrollt (Mapbox-Karte): nach 10 s ohne Eingabe zurück zum Standort
        .onChange(of: viewport) { _, new in
            guard !satellite, new == .idle else { return }
            idleToken += 1
            let token = idleToken
            Task {
                try? await Task.sleep(for: .seconds(10))
                if token == idleToken, viewport == .idle {
                    withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !satellite { withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport } }
        }
        .onChange(of: zoomSteps) { _, _ in
            withViewportAnimation(.easeOut(duration: 0.35)) { viewport = followViewport }
        }
        .onChange(of: threeD) { _, _ in
            withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport }
        }
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

            // Routen der Freunde
            ForEvery(Array(app.routes.friendRoutes.values)) { route in
                PolylineAnnotation(id: "route-\(route.friendId)", lineCoordinates: route.coordinates)
                    .lineColor(FriendPalette.uiColor(for: route.friendId))
                    .lineWidth(5)
                    .lineOpacity(0.85)
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
                    .textOffset(x: 0, y: 0.8)
                    .textSize(13)
                    .textColor(StyleColor(.white))
                    .textHaloColor(StyleColor(.black))
                    .textHaloWidth(1.5)
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
        .mapStyle(.standard(lightPreset: .night))
        .ignoresSafeArea()
    }

    /// Pin setzen und Adresse nachladen
    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        let id = "pin-\(coordinate.latitude),\(coordinate.longitude)"
        droppedPin = Place(id: id, name: "Gesetzter Pin", address: nil, coordinate: coordinate)
        setChrome(hidden: false)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            let marks = try? await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard let mark = marks?.first, droppedPin?.id == id else { return }
            let street = [mark.thoroughfare, mark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
            let city = [mark.postalCode, mark.locality].compactMap { $0 }.joined(separator: " ")
            let name = mark.name ?? (street.isEmpty ? "Gesetzter Pin" : street)
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

    private var mapControls: some View {
        VStack(spacing: 8) {
            CircleIconButton(
                systemName: satellite ? "map.fill" : "globe.europe.africa.fill",
                label: satellite ? "Zur klassischen Karte wechseln" : "Zur Satellitenansicht wechseln"
            ) { satellite.toggle() }

            let incognito = app.profile?.isIncognito ?? false
            CircleIconButton(
                systemName: incognito ? "eye.slash.fill" : "eye.slash",
                label: incognito ? "Inkognito-Modus beenden" : "Inkognito-Modus aktivieren",
                tint: incognito ? Theme.accent : Theme.text
            ) {
                if incognito { Task { await app.stopIncognito() } } else { showIncognito = true }
            }

            Button { threeD.toggle() } label: {
                Text(threeD ? "2D" : "3D")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.panel))
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .accessibilityLabel(threeD ? "Zur 2D-Ansicht wechseln" : "Zur 3D-Ansicht wechseln")

            CircleIconButton(systemName: "location.north.line.fill", label: "Auf meinen Standort zentrieren", tint: Theme.accent) {
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
        Button {
            Task {
                if incognito {
                    await app.stopIncognito()
                } else if sharing {
                    await app.auth.setSharing(false)
                } else {
                    let until: Date? = SharingMode.current == .oneHour ? Date().addingTimeInterval(3600) : nil
                    await app.auth.setSharing(true, until: until)
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
        .accessibilityHint(incognito ? "Tippen beendet Inkognito" : sharing ? "Tippen pausiert das Teilen" : "Tippen teilt deinen Standort wieder")
    }

    private func label(_ profile: Profile?) -> String {
        if let profile, profile.isIncognito {
            if profile.isIncognitoIndefinitely { return "Inkognito" }
            if let until = profile.incognitoUntil { return "Inkognito bis \(Format.time.string(from: until))" }
        }
        guard let profile, profile.isSharingNow else { return "Teilen pausiert" }
        if let until = profile.sharingUntil { return "Teilst live bis \(Format.time.string(from: until))" }
        return "Teilst live"
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if app.friends.accepted.isEmpty {
                        Text("Noch keine Freunde. Füge jemanden über den Benutzernamen hinzu.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    } else {
                        Text("\(app.friendsOnMap.count) von \(app.friends.accepted.count) sichtbar")
                            .font(.footnote).foregroundStyle(Theme.muted)
                        ForEach(app.friendsOnMap) { item in
                            FriendRowView(item: item)
                        }
                        if app.friendsOnMap.isEmpty {
                            Text("Gerade teilt niemand seinen Standort.")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                        }
                    }
                    Button(app.friends.accepted.isEmpty ? "Freunde hinzufügen" : "Freunde & Profil") {
                        manageFriends()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
                }
                .padding(16)
            }
            .background(Theme.ink)
            .navigationTitle("Unterwegs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.ink)
    }
}

private struct FriendRowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: AppModel.FriendOnMap

    var body: some View {
        let route = app.routes.friendRoutes[item.friend.friendId]
        let distance = app.location.lastLocation.map { item.position.coordinate.distance(to: $0.coordinate) }

        Menu {
            Button("Route zu \(item.friend.displayName)", systemImage: "arrow.triangle.turn.up.right.diamond") {
                go(to: Place(
                    id: "friend-\(item.friend.friendId)", name: item.friend.displayName,
                    address: nil, coordinate: item.position.coordinate))
            }
            if let route {
                Button("Zum Ziel von \(item.friend.displayName)", systemImage: "flag.checkered") {
                    go(to: Place(
                        id: "dest-\(item.friend.friendId)", name: route.destinationName ?? "Ziel von \(item.friend.displayName)",
                        address: nil, coordinate: route.destination))
                }
            }
        } label: {
            HStack(spacing: 12) {
                Avatar(initials: item.friend.initials, color: FriendPalette.color(for: item.friend.friendId), userId: item.friend.friendId)
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
        if let route {
            let dest = route.destinationName.map { "Nach \($0)" } ?? "Unterwegs"
            return "\(dest) · an \(Format.time.string(from: route.eta))"
        }
        return item.position.age < 60 ? "Live" : "Zuletzt \(Format.age(item.position.age))"
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
