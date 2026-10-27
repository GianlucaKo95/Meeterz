import SwiftUI
import CoreLocation

/// Erscheint beim Tippen auf einen Freund auf der Karte: Profil, auf der Karte zeigen, hin navigieren.
struct FriendActionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let friendId: UUID
    @State private var showProfile = false

    private var item: AppModel.FriendOnMap? { app.friendsOnMap.first { $0.friend.friendId == friendId } }

    var body: some View {
        NavigationStack {
            if let item {
                let route = app.routes.friendRoutes[friendId]
                VStack(alignment: .leading, spacing: 16) {
                    header(item, route: route)
                    if let last = lastMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "bubble.left.fill").font(.caption).foregroundStyle(Theme.accent)
                            Text(last.incoming ? last.body : "Du: \(last.body)").font(.subheadline).foregroundStyle(Theme.text)
                            Spacer(minLength: 4)
                            Text(Format.time.string(from: last.createdAt)).font(.caption2).foregroundStyle(Theme.muted)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    }

                    VStack(spacing: 10) {
                        Button { showProfile = true } label: {
                            Label("Profil anzeigen", systemImage: "person.crop.circle")
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button {
                            app.mapFocus = .init(friendId: friendId, showRoute: route != nil)
                            dismiss()
                        } label: {
                            Label(route == nil ? String(localized: "Auf Karte anzeigen") : String(localized: "Route anzeigen"),
                                  systemImage: route == nil ? "mappin.and.ellipse" : "point.topleft.down.to.point.bottomright.curvepath")
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button {
                            go(Place(id: "friend-\(friendId)", name: item.friend.displayName, address: nil,
                                     coordinate: item.position.coordinate))
                        } label: {
                            Label("Zu \(item.friend.displayName) navigieren", systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                        .buttonStyle(PrimaryButtonStyle())

                        Menu {
                            ForEach(MessagesStore.quickReplies(eta: myEta), id: \.self) { text in
                                Button(text) { send(text) }
                            }
                        } label: {
                            Label("Kurz Bescheid geben", systemImage: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(Capsule().stroke(Theme.stroke, lineWidth: 1))
                        }
                        .accessibilityIdentifier("friend-quick-reply")

                        if let route {
                            Button {
                                go(Place(id: "dest-\(friendId)", name: route.destinationName ?? String(localized: "Ziel von \(item.friend.displayName)"),
                                         address: nil, coordinate: route.destination))
                            } label: {
                                Label("Zum Ziel von \(item.friend.displayName) navigieren", systemImage: "flag.checkered")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .background(Theme.ink.ignoresSafeArea())
                .navigationDestination(isPresented: $showProfile) { profile(item, route: route) }
            } else {
                ProgressView().onAppear { dismiss() }
            }
        }
        .presentationDetents([.height(lastMessage == nil ? 460 : 520), .large])
        .presentationDragIndicator(.visible)
    }

    private func header(_ item: AppModel.FriendOnMap, route: FriendRoute?) -> some View {
        HStack(spacing: 14) {
            Avatar(initials: item.friend.initials, color: FriendPalette.color(for: friendId), size: 56, userId: friendId)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.friend.displayName).font(Theme.display(24))
                Text(status(item, route: route)).font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }

    private func status(_ item: AppModel.FriendOnMap, route: FriendRoute?) -> String {
        if let route {
            let dest = route.destinationName.map { String(localized: "Nach \($0)") } ?? String(localized: "Unterwegs")
            return String(localized: "\(dest) · an \(Format.time.string(from: route.eta))")
        }
        return String(localized: "Standort \(Format.age(item.position.age))")
    }

    private func profile(_ item: AppModel.FriendOnMap, route: FriendRoute?) -> some View {
        let distance = app.location.lastLocation.map { item.position.coordinate.distance(to: $0.coordinate) }
        return ScrollView {
            VStack(spacing: 16) {
                Avatar(initials: item.friend.initials, color: FriendPalette.color(for: friendId), size: 110, userId: friendId)
                Text(item.friend.displayName).font(Theme.display(28))
                Text("@\(item.friend.handle)").foregroundStyle(Theme.muted)

                VStack(spacing: 0) {
                    row(String(localized: "Standort"), Format.age(item.position.age))
                    if let distance { row(String(localized: "Entfernung"), Format.distance(distance)) }
                    if item.position.speed.map({ $0 > 1 }) == true, let speed = item.position.speed {
                        row(String(localized: "Tempo"), String(localized: "\(Int((speed * 3.6).rounded())) km/h"))
                    }
                    if let route {
                        row(String(localized: "Ziel"), route.destinationName ?? String(localized: "Unterwegs"))
                        row(String(localized: "Ankunft"), Format.time.string(from: route.eta))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            }
            .padding(20)
        }
        .background(Theme.ink.ignoresSafeArea())
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).font(.body.weight(.semibold))
        }
        .padding(14)
    }

    private var lastMessage: MessagesStore.Message? {
        app.messages.messages.first { $0.otherId == friendId }
    }

    /// Eigene Ankunftszeit, falls gerade navigiert wird
    private var myEta: Date? { app.navigation.isNavigating ? app.navigation.eta : nil }

    private func send(_ text: String) {
        Task {
            let n = await app.messages.send(text, to: [friendId])
            app.show(n > 0 ? String(localized: "Gesendet") : String(localized: "Nachricht nicht gesendet"), isError: n == 0)
        }
    }

    /// Fenster schließen, dann Route planen – die Vorschau kann erst nach dem Schließen erscheinen.
    private func go(_ place: Place) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            await app.navigation.planRoute(to: place)
        }
    }
}
