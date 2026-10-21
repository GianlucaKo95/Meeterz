import SwiftUI
import MapKit

/// Satellitenansicht mit Apples Flyover (fotorealistische 3D-Städte), soweit Apple für den Ort Flyover-Daten hat.
/// Außerhalb davon zeigt MapKit normales Satellitenbild mit Gelände.
struct FlyoverMapView: View {
    @Environment(AppModel.self) private var app
    @Binding var plannedMeetup: MeetupCandidate?
    @Binding var droppedPin: Place?
    /// Langer Druck auf die Karte
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }
    let threeD: Bool
    /// Zählt hoch, wenn „Auf meinen Standort zentrieren“ getippt wurde
    let recenterTick: Int
    /// Zoomstufen der Plus/Minus-Knöpfe; jede Stufe halbiert bzw. verdoppelt den Abstand
    let zoomSteps: Int

    @State private var position: MapCameraPosition = .automatic
    @State private var detail: PlaceDetailItem?
    @State private var lastCamera: MapCamera?
    @State private var idleToken = 0
    @Environment(\.scenePhase) private var scenePhase

    @Namespace private var compassScope

    var body: some View {
        MapReader { proxy in
            mapContent
                // Tipp aufs Kartenbild: nächstgelegenen Ort in der Nähe suchen und Apples Ortsdetails zeigen
                .onTapGesture(count: 1, coordinateSpace: .local) { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    openPlace(near: coordinate)
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.6)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            if case .second(true, let drag?) = value,
                               let coordinate = proxy.convert(drag.location, from: .local) {
                                onLongPress(coordinate)
                            }
                        }
                )
        }
    }

    /// Orte (Restaurant, Café, Tankstelle …) in Tippnähe; der Suchradius wächst mit dem Kartenabstand
    private func openPlace(near coordinate: CLLocationCoordinate2D) {
        guard detail == nil else { return }
        let distance = lastCamera?.distance ?? 1000
        let radius = min(max(distance * 0.05, 20), 150)
        Task {
            let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant, .cafe, .parking, .gasStation, .publicTransport, .hospital, .bakery, .pharmacy, .hotel, .museum, .park, .store, .foodMarket, .evCharger])
            guard let response = try? await MKLocalSearch(request: request).start() else { return }
            let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let nearest = response.mapItems.min {
                CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: target)
                < CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude).distance(from: target)
            }
            Diag.log("Kartentipp: \(nearest?.name ?? "kein Ort in \(Int(radius)) m")")
            if let nearest, detail == nil { detail = PlaceDetailItem(mapItem: nearest) }
        }
    }

    /// Tipp auf ein POI: Auswahl sofort wieder zurücknehmen und Apples Ortsdetails laden
    private var featureSelection: Binding<MapFeature?> {
        Binding(get: { nil }, set: { feature in
            guard let feature else { return }
            Diag.log("POI getippt: \(feature.title ?? "ohne Namen")")
            Task {
                do {
                    let item = try await MKMapItemRequest(feature: feature).mapItem
                    detail = PlaceDetailItem(mapItem: item)
                } catch {
                    // Kein Apple-Eintrag: einfache Ortskarte aus Name und Position
                    Diag.log("POI-Details nicht geladen: \(error.localizedDescription)")
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: feature.coordinate))
                    item.name = feature.title
                    detail = PlaceDetailItem(mapItem: item)
                }
            }
        })
    }

    @MapContentBuilder
    private var friendAndMeetupContent: some MapContent {
        ForEach(app.friendsOnMap) { item in
            Annotation(item.friend.displayName, coordinate: item.position.coordinate, anchor: .bottom) {
                FriendMarker(friend: item.friend, position: item.position)
                    .environment(app)
                    .onTapGesture { app.selectedFriend = item.id }
            }
            .annotationTitles(.hidden)
        }

        ForEach(app.meetups.visibleCandidates) { candidate in
            Annotation("Möglicher Treffpunkt", coordinate: candidate.coordinate) {
                Button { plannedMeetup = candidate } label: {
                    Image(systemName: "figure.2.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.ink, Theme.accent)
                        .shadow(radius: 4)
                }
                .accessibilityLabel("Möglicher Treffpunkt")
            }
            .annotationTitles(.hidden)
        }

        ForEach(app.meetups.accepted) { meetup in
            Annotation(meetup.placeName, coordinate: meetup.coordinate, anchor: .bottom) {
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
            .annotationTitles(.hidden)
        }
    }

    private var mapBase: some View {
        Map(position: $position, selection: featureSelection, scope: compassScope) {
            UserAnnotation()

            if let pin = droppedPin {
                Annotation(pin.name, coordinate: pin.coordinate, anchor: .bottom) {
                    DroppedPinMarker()
                }
                .annotationTitles(.hidden)
            }

            // Routen der Freunde: dunkle Umrandung, darüber knallige Farbe (die gezeigte Route etwas breiter)
            ForEach(Array(app.routes.friendRoutes.values)) { route in
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Color(uiColor: FriendPalette.routeCasing), lineWidth: app.mapFocus?.friendId == route.friendId ? 13 : 10)
            }
            ForEach(Array(app.routes.friendRoutes.values)) { route in
                MapPolyline(coordinates: route.coordinates)
                    .stroke(FriendPalette.routeColor(for: route.friendId), lineWidth: app.mapFocus?.friendId == route.friendId ? 8 : 6)
            }
            if let focus = app.mapFocus, focus.showRoute, let route = app.routes.friendRoutes[focus.friendId] {
                Annotation("Ziel", coordinate: route.destination, anchor: .center) {
                    Image(systemName: "flag.checkered.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.black, FriendPalette.routeColor(for: route.friendId))
                        .shadow(radius: 3)
                }
                .annotationTitles(.hidden)
            }

            friendAndMeetupContent
        }
        .mapStyle(.hybrid(elevation: .realistic, pointsOfInterest: .including([.publicTransport, .restaurant, .cafe, .parking, .hospital])))
        .mapControls { }
        .overlay(alignment: .topTrailing) {
            MapCompass(scope: compassScope)
                .mapControlVisibility(.automatic)
                .padding(.top, 400).padding(.trailing, 22)
        }
        .mapScope(compassScope)
    }

    /// POI antippen → Apples Ortsdetails
    private var mapDetail: some View {
        mapBase
        .sheet(item: $detail) { item in
            PlaceDetailSheet(item: item) { place in
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    await app.navigation.planRoute(to: place)
                }
            }
        }
    }

    private var mapContent: some View {
        mapDetail
        .ignoresSafeArea()
        .onMapCameraChange(frequency: .continuous) { context in lastCamera = context.camera }
        // Weggescrollt: nach 10 s ohne Eingabe zurück zum eigenen Standort
        .onMapCameraChange(frequency: .onEnd) { _ in
            guard position.positionedByUser else { return }
            idleToken += 1
            let token = idleToken
            Task {
                try? await Task.sleep(for: .seconds(10))
                if token == idleToken, position.positionedByUser, app.mapFocus == nil { follow(force: true) }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { follow(force: true) } }
        .onChange(of: app.mapFocus) { _, focus in if let focus { show(focus) } }
        .onAppear { follow(force: true) }
        .onChange(of: zoomSteps) { old, new in zoom(by: new - old) }
        .onChange(of: recenterTick) { _, _ in follow(force: true) }
        .onChange(of: threeD) { _, _ in follow(force: true) }
        .onChange(of: app.location.lastLocation) { _, _ in follow(force: false) }
    }

    /// Kamera folgt dem eigenen Standort, solange man die Karte nicht selbst verschoben hat.
    private func follow(force: Bool) {
        guard let loc = app.location.lastLocation else { return }
        guard force || (!position.positionedByUser && app.mapFocus == nil) else { return }
        let camera = MapCamera(
            centerCoordinate: loc.coordinate,
            distance: (threeD ? 650 : 5000) * pow(2, -Double(zoomSteps)),
            heading: threeD && loc.course >= 0 ? loc.course : 0,
            pitch: threeD ? 65 : 0
        )
        withAnimation(.easeOut(duration: 0.8)) { position = .camera(camera) }
    }

    /// Zeigt den Freund (und seine restliche Route) im oberen Teil der Karte, damit das halbhohe Unterwegs-Fenster nichts verdeckt.
    private func show(_ focus: AppModel.MapFocus) {
        guard let item = app.friendsOnMap.first(where: { $0.friend.friendId == focus.friendId }) else { return }
        var points = [item.position.coordinate]
        if focus.showRoute, let route = app.routes.friendRoutes[focus.friendId] {
            points += route.coordinates
        }
        let mapPoints = points.map(MKMapPoint.init)
        var rect = mapPoints.dropFirst().reduce(MKMapRect(origin: mapPoints[0], size: MKMapSize(width: 0, height: 0))) {
            $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0)))
        }
        // Mindestausschnitt ≈ 700 m, damit ein einzelner Freund nicht extrem nah gezeigt wird
        let minSide = MKMapPointsPerMeterAtLatitude(item.position.coordinate.latitude) * 700
        if rect.width < minSide { rect = rect.insetBy(dx: -(minSide - rect.width) / 2, dy: 0) }
        if rect.height < minSide { rect = rect.insetBy(dx: 0, dy: -(minSide - rect.height) / 2) }
        // Inhalt in das Band 22–78 % der Bildhöhe (Fenster ist geschlossen, oben liegt die Leiste)
        let content = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
        let screen = UIScreen.main.bounds.size
        let aspect = screen.width / screen.height
        let height = max(content.height / 0.56, content.width / aspect)
        let width = height * aspect
        let target = MKMapRect(x: content.midX - width / 2, y: content.minY - 0.22 * height, width: width, height: height)
        withAnimation(.easeOut(duration: 0.8)) { position = .rect(target) }
    }

    /// Zoomt die aktuelle Kamera (auch nach Verschieben/Pinch), Blickrichtung und Neigung bleiben.
    private func zoom(by delta: Int) {
        guard delta != 0, let cam = lastCamera else { return }
        let distance = min(max(cam.distance * pow(2, -Double(delta)), 120), 60_000)
        let next = MapCamera(centerCoordinate: cam.centerCoordinate, distance: distance, heading: cam.heading, pitch: cam.pitch)
        withAnimation(.easeOut(duration: 0.4)) { position = .camera(next) }
    }
}
