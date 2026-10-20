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
    @State private var lastCamera: MapCamera?
    @State private var idleToken = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MapReader { proxy in
            mapContent
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

    private var mapContent: some View {
        Map(position: $position) {
            UserAnnotation()

            if let pin = droppedPin {
                Annotation(pin.name, coordinate: pin.coordinate, anchor: .bottom) {
                    DroppedPinMarker()
                }
                .annotationTitles(.hidden)
            }

            ForEach(Array(app.routes.friendRoutes.values)) { route in
                MapPolyline(coordinates: route.coordinates)
                    .stroke(FriendPalette.color(for: route.friendId).opacity(0.9), lineWidth: 5)
            }

            ForEach(app.friendsOnMap) { item in
                Annotation(item.friend.displayName, coordinate: item.position.coordinate, anchor: .bottom) {
                    FriendMarker(friend: item.friend, position: item.position)
                        .environment(app)
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
        .mapStyle(.hybrid(elevation: .realistic, pointsOfInterest: .including([.publicTransport, .restaurant, .cafe, .parking, .hospital])))
        .mapControls { }
        .ignoresSafeArea()
        .onMapCameraChange(frequency: .continuous) { context in lastCamera = context.camera }
        // Weggescrollt: nach 10 s ohne Eingabe zurück zum eigenen Standort
        .onMapCameraChange(frequency: .onEnd) { _ in
            guard position.positionedByUser else { return }
            idleToken += 1
            let token = idleToken
            Task {
                try? await Task.sleep(for: .seconds(10))
                if token == idleToken, position.positionedByUser { follow(force: true) }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { follow(force: true) } }
        .onAppear { follow(force: true) }
        .onChange(of: zoomSteps) { old, new in zoom(by: new - old) }
        .onChange(of: recenterTick) { _, _ in follow(force: true) }
        .onChange(of: threeD) { _, _ in follow(force: true) }
        .onChange(of: app.location.lastLocation) { _, _ in follow(force: false) }
    }

    /// Kamera folgt dem eigenen Standort, solange man die Karte nicht selbst verschoben hat.
    private func follow(force: Bool) {
        guard let loc = app.location.lastLocation else { return }
        guard force || !position.positionedByUser else { return }
        let camera = MapCamera(
            centerCoordinate: loc.coordinate,
            distance: (threeD ? 650 : 5000) * pow(2, -Double(zoomSteps)),
            heading: threeD && loc.course >= 0 ? loc.course : 0,
            pitch: threeD ? 65 : 0
        )
        withAnimation(.easeOut(duration: 0.8)) { position = .camera(camera) }
    }

    /// Zoomt die aktuelle Kamera (auch nach Verschieben/Pinch), Blickrichtung und Neigung bleiben.
    private func zoom(by delta: Int) {
        guard delta != 0, let cam = lastCamera else { return }
        let distance = min(max(cam.distance * pow(2, -Double(delta)), 120), 60_000)
        let next = MapCamera(centerCoordinate: cam.centerCoordinate, distance: distance, heading: cam.heading, pitch: cam.pitch)
        withAnimation(.easeOut(duration: 0.4)) { position = .camera(next) }
    }
}
