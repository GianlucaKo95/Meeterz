import SwiftUI
import MapboxMaps

struct MainView: View {
    @Environment(AppModel.self) private var app

    @AppStorage("map.satellite") private var satellite = true
    @AppStorage("map.3d") private var threeD = true

    @State private var viewport: Viewport = .idle
    @State private var showFriends = false
    @State private var showSearch = false
    @State private var plannedMeetup: MeetupCandidate?

    /// Kamera folgt dem eigenen Standort – in 3D schräg von hinten, in Fahrtrichtung gedreht
    private var followViewport: Viewport {
        threeD
            ? .followPuck(zoom: 16.5, bearing: .course, pitch: 60)
            : .followPuck(zoom: 13)
    }

    var body: some View {
        @Bindable var navigation = app.navigation

        ZStack(alignment: .top) {
            map

            VStack(spacing: 10) {
                topBar
                HStack(alignment: .top) {
                    SharingPill()
                    Spacer()
                    mapControls
                }
                if let banner = app.banner {
                    BannerView(banner: banner) { app.dismissBanner() }
                }
            }
            .padding(.horizontal, 16)

            VStack(spacing: 10) {
                Spacer()
                SocialCards(plannedMeetup: $plannedMeetup)
                UnterwegsPanel(showFriends: $showFriends)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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

            // 3D-Gebäude auf dem Satellitenbild. Die klassische Karte (Standard) bringt sie schon mit.
            if threeD && satellite {
                VectorSource(id: "mapbox-streets")
                    .url("mapbox://mapbox.mapbox-streets-v8")
                FillExtrusionLayer(id: "satellite-3d-buildings", source: "mapbox-streets")
                    .sourceLayer("building")
                    .filter(Exp(.eq) { Exp(.get) { "extrude" }; "true" })
                    .minZoom(14.5)
                    .fillExtrusionColor(UIColor(red: 0.82, green: 0.80, blue: 0.76, alpha: 1))
                    .fillExtrusionOpacity(0.75)
                    .fillExtrusionHeight(Exp(.get) { "height" })
                    .fillExtrusionBase(Exp(.get) { "min_height" })
                    .slot(.middle)
            }

            // Routen der Freunde
            ForEvery(Array(app.routes.friendRoutes.values)) { route in
                PolylineAnnotation(id: "route-\(route.friendId)", lineCoordinates: route.coordinates)
                    .lineColor(FriendPalette.uiColor(for: route.friendId))
                    .lineWidth(5)
                    .lineOpacity(0.85)
            }

            // Freunde live
            ForEvery(app.friendsOnMap) { item in
                MapViewAnnotation(coordinate: item.position.coordinate) {
                    FriendMarker(friend: item.friend, position: item.position)
                }
                .allowOverlap(true)
            }

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
        .mapStyle(satellite ? .standardSatellite : .standard(lightPreset: .night))
        .ignoresSafeArea()
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
                badge: !app.friends.incoming.isEmpty
            ) { showFriends = true }
        }
        .padding(.top, 8)
    }

    private var mapControls: some View {
        VStack(spacing: 8) {
            CircleIconButton(
                systemName: satellite ? "map.fill" : "globe.europe.africa.fill",
                label: satellite ? "Zur klassischen Karte wechseln" : "Zur Satellitenansicht wechseln"
            ) { satellite.toggle() }

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

struct SharingPill: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let profile = app.profile
        let sharing = profile?.isSharingNow ?? false
        Button {
            Task {
                if sharing {
                    await app.auth.setSharing(false)
                } else {
                    let until: Date? = SharingMode.current == .oneHour ? Date().addingTimeInterval(3600) : nil
                    await app.auth.setSharing(true, until: until)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(sharing ? Theme.accent : Theme.muted).frame(width: 8, height: 8)
                Text(label(profile))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(sharing ? Theme.accent : Theme.muted)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Theme.panel.opacity(0.92)))
        }
        .accessibilityHint(sharing ? "Tippen pausiert das Teilen" : "Tippen teilt deinen Standort wieder")
    }

    private func label(_ profile: Profile?) -> String {
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

struct UnterwegsPanel: View {
    @Environment(AppModel.self) private var app
    @Binding var showFriends: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Unterwegs").font(Theme.display(22))
                Spacer()
                Text(app.friends.accepted.isEmpty ? "" : "\(app.friendsOnMap.count) von \(app.friends.accepted.count) sichtbar")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }

            if app.friends.accepted.isEmpty {
                Text("Noch keine Freunde. Füge jemanden über den Benutzernamen hinzu.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                Button("Freunde hinzufügen") { showFriends = true }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                ForEach(app.friendsOnMap.prefix(3)) { item in
                    FriendRowView(item: item)
                }
                if app.friendsOnMap.isEmpty {
                    Text("Gerade teilt niemand seinen Standort.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 26).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Theme.stroke, lineWidth: 1))
    }
}

private struct FriendRowView: View {
    @Environment(AppModel.self) private var app
    let item: AppModel.FriendOnMap

    var body: some View {
        let route = app.routes.friendRoutes[item.friend.friendId]
        let distance = app.location.lastLocation.map { item.position.coordinate.distance(to: $0.coordinate) }

        Menu {
            Button("Route zu \(item.friend.displayName)", systemImage: "arrow.triangle.turn.up.right.diamond") {
                Task {
                    await app.navigation.planRoute(to: Place(
                        id: "friend-\(item.friend.friendId)", name: item.friend.displayName,
                        address: nil, coordinate: item.position.coordinate))
                }
            }
            if let route {
                Button("Zum Ziel von \(item.friend.displayName)", systemImage: "flag.checkered") {
                    Task {
                        await app.navigation.planRoute(to: Place(
                            id: "dest-\(item.friend.friendId)", name: route.destinationName ?? "Ziel von \(item.friend.displayName)",
                            address: nil, coordinate: route.destination))
                    }
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

    private func statusText(route: FriendRoute?) -> String {
        if let route {
            let dest = route.destinationName.map { "Nach \($0)" } ?? "Unterwegs"
            return "\(dest) · an \(Format.time.string(from: route.eta))"
        }
        return item.position.age < 60 ? "Live" : "Zuletzt \(Format.age(item.position.age))"
    }
}
