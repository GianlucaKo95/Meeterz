import SwiftUI
import MapboxMaps

struct MainView: View {
    @Environment(AuthStore.self) private var auth
    let profile: Profile

    @State private var location = LocationService()
    @State private var friends = FriendsStore()
    @State private var hub = LiveLocationHub()
    @State private var showFriends = false
    @State private var viewport: Viewport = .idle
    @AppStorage("map.satellite") private var satellite = true
    @AppStorage("map.3d") private var threeD = true

    /// Kamera folgt dem eigenen Standort – in 3D schräg von hinten, in Fahrtrichtung gedreht
    private var followViewport: Viewport {
        threeD
            ? .followPuck(zoom: 16.5, bearing: .course, pitch: 60)
            : .followPuck(zoom: 13)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(viewport: $viewport) {
                Puck2D(bearing: threeD ? .course : .heading)

                // 3D-Landschaft: Höhenmodell, leicht überhöht damit Hügel sichtbar werden
                if threeD {
                    RasterDemSource(id: "mapbox-dem")
                        .url("mapbox://mapbox.mapbox-terrain-dem-v1")
                        .tileSize(514)
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
                ForEvery(markers) { m in
                    MapViewAnnotation(coordinate: m.position.coordinate) {
                        FriendMarker(marker: m)
                    }
                    .allowOverlap(true)
                }
            }
            .mapStyle(satellite ? .standardSatellite : .standard)
            .ignoresSafeArea()

            HStack {
                SharingPill(enabled: profile.sharingEnabled) {
                    Task { await auth.setSharing(!profile.sharingEnabled) }
                }
                Spacer()
                // Ein Tipp: Satellit ↔ klassische Karte
                Button { satellite.toggle() } label: {
                    Image(systemName: satellite ? "map.fill" : "globe.europe.africa.fill").padding(12)
                }
                .accessibilityLabel(satellite ? "Zur klassischen Karte wechseln" : "Zur Satellitenansicht wechseln")
                .background(.regularMaterial, in: Circle())
                Button { threeD.toggle() } label: {
                    Text(threeD ? "2D" : "3D").font(.footnote.bold()).frame(width: 20).padding(12)
                }
                .accessibilityLabel(threeD ? "Zur 2D-Ansicht wechseln" : "Zur 3D-Ansicht wechseln")
                .background(.regularMaterial, in: Circle())
                Button { viewport = followViewport } label: {
                    Image(systemName: "location.fill").padding(12)
                }
                .background(.regularMaterial, in: Circle())
                Button { showFriends = true } label: {
                    Image(systemName: "person.2.fill").padding(12)
                }
                .background(.regularMaterial, in: Circle())
                .overlay(alignment: .topTrailing) {
                    if !friends.incoming.isEmpty {
                        Circle().fill(.red).frame(width: 10, height: 10)
                    }
                }
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showFriends) {
            FriendsView(profile: profile, store: friends, location: location)
        }
        .task { await bootstrap() }
        .task(id: friends.rows) { await hub.sync(with: friends.rows) }
        .onChange(of: profile.sharingEnabled) { _, _ in wireLocation() }
        .onChange(of: threeD) { _, _ in
            withViewportAnimation(.easeOut(duration: 0.6)) { viewport = followViewport }
        }
        .onAppear { viewport = followViewport }
    }

    private var markers: [FriendMarkerModel] {
        friends.accepted.compactMap { f in
            hub.positions[f.friendId].map { FriendMarkerModel(friend: f, position: $0) }
        }
    }

    private func bootstrap() async {
        wireLocation()
        location.requestPermission()
        await hub.startPublishing(userId: profile.id)
        // Freundesliste regelmäßig aktualisieren (neue Anfragen, Freigaben)
        while !Task.isCancelled {
            await friends.refresh()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func wireLocation() {
        let userId = profile.id
        let sharing = profile.sharingEnabled
        location.onUpdate = { loc in
            Task { await hub.publish(loc, userId: userId, sharingEnabled: sharing) }
        }
    }
}

struct FriendMarkerModel: Identifiable {
    let friend: FriendRow
    let position: LivePosition
    var id: UUID { friend.friendId }
}

struct FriendMarker: View {
    let marker: FriendMarkerModel

    var body: some View {
        // TimelineView sorgt dafür, dass "vor X Min." mitläuft
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let age = marker.position.age
            let stale = age > 5 * 60
            VStack(spacing: 2) {
                Text(initials)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(color))
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(radius: 2)
                Text("\(marker.friend.displayName) · \(ageText(age))")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
            }
            .opacity(stale ? 0.5 : 1)
        }
    }

    private var initials: String {
        marker.friend.displayName.split(separator: " ").prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var color: Color {
        let hues: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo]
        // Stabil über App-Starts hinweg (hashValue wäre pro Start zufällig)
        return hues[Int(marker.friend.friendId.uuid.0) % hues.count]
    }

    private func ageText(_ age: TimeInterval) -> String {
        if age < 60 { return "live" }
        if age < 3600 { return "vor \(Int(age / 60)) Min." }
        return "vor \(Int(age / 3600)) Std."
    }
}

struct SharingPill: View {
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(enabled ? "Teilt Standort" : "Teilen pausiert",
                  systemImage: enabled ? "dot.radiowaves.left.and.right" : "pause.circle")
                .font(.footnote.bold())
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .tint(enabled ? .green : .secondary)
        .background(.regularMaterial, in: Capsule())
    }
}
