import SwiftUI
import MapKit

/// Satellitenansicht mit Apples Flyover (fotorealistische 3D-Städte), soweit Apple für den Ort Flyover-Daten hat.
/// Außerhalb davon zeigt MapKit normales Satellitenbild mit Gelände.
struct FlyoverMapView: View {
    @Environment(AppModel.self) private var app
    @Binding var plannedMeetup: MeetupCandidate?
    let threeD: Bool
    /// Zählt hoch, wenn „Auf meinen Standort zentrieren“ getippt wurde
    let recenterTick: Int

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            UserAnnotation()

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
        .onAppear { follow(force: true) }
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
            distance: threeD ? 650 : 5000,
            heading: threeD && loc.course >= 0 ? loc.course : 0,
            pitch: threeD ? 65 : 0
        )
        withAnimation(.easeOut(duration: 0.8)) { position = .camera(camera) }
    }
}
