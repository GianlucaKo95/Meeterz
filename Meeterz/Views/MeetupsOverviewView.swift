import SwiftUI
import CoreLocation

/// „Treffen“: zugesagte und offene Treffen mit Teilnehmern, Ankunftszeiten, „ist da“,
/// den letzten Nachrichten und Schnellantworten.
struct MeetupsOverviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Ein Treffen (Gruppen-Einladungen derselben Gruppe zusammengefasst)
    struct Entry: Identifiable {
        let id: UUID
        let meetups: [Meetup]
        var first: Meetup { meetups[0] }
        var accepted: Bool { meetups.contains(where: \.isAccepted) }
    }

    private var entries: [Entry] {
        let relevant = app.meetups.meetups.filter { $0.isAccepted || $0.isPending }
        var order: [UUID] = []
        var groups: [UUID: [Meetup]] = [:]
        for m in relevant {
            let key = m.groupId ?? m.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(m)
        }
        return order.map { Entry(id: $0, meetups: groups[$0]!) }
            .sorted { ($0.accepted ? 0 : 1, $0.first.createdAt) < ($1.accepted ? 0 : 1, $1.first.createdAt) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "calendar.badge.clock").font(.largeTitle).foregroundStyle(Theme.muted)
                            Text("Keine Treffen geplant").font(Theme.title())
                            Text("Plane ein Treffen über einen Freund oder „Gruppen-Treffen planen“.")
                                .font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(entries) { entry in
                        MeetupCard(entry: entry) { place in
                            dismiss()
                            Task {
                                try? await Task.sleep(for: .milliseconds(450))
                                await app.navigation.planRoute(to: place)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.ink)
            .navigationTitle("Treffen")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ink)
    }
}

private struct MeetupCard: View {
    @Environment(AppModel.self) private var app
    let entry: MeetupsOverviewView.Entry
    let navigate: (Place) -> Void
    @State private var members: [MeetupsStore.GroupMember] = []
    @State private var sending = false

    struct Participant: Identifiable {
        let id: UUID
        let name: String
        let status: String
        let arrived: Bool
        let accepted: Bool
    }

    private var meetup: Meetup { entry.first }

    /// Teilnehmer außer mir: bei Gruppen vom Server, sonst das Gegenüber
    private var participants: [Participant] {
        let me = app.auth.profile?.id
        let base: [(UUID, String, Bool)] = members.isEmpty
            ? entry.meetups.map { ($0.otherId, $0.otherName, $0.isAccepted) }
            : members.filter { $0.userId != me }.map { ($0.userId, $0.displayName, $0.status == "accepted" || $0.organizer) }
        return base.map { id, name, accepted in
            let (status, arrived) = state(of: id)
            return Participant(id: id, name: name, status: accepted ? status : String(localized: "noch nicht zugesagt"), arrived: arrived, accepted: accepted)
        }
    }

    /// „ist da“, „an 18:40“ (Route zum Treffpunkt) oder Entfernung
    private func state(of id: UUID) -> (String, Bool) {
        let target = meetup.coordinate
        if let pos = app.hub.positions[id] {
            let d = pos.coordinate.distance(to: target)
            if d < 150, pos.age < 600 { return (String(localized: "ist da"), true) }
            if let route = app.routes.friendRoutes[id], route.destination.distance(to: target) < 300 {
                return (String(localized: "unterwegs · an \(Format.time.string(from: route.eta))"), false)
            }
            return (String(localized: "\(Format.distance(d)) entfernt"), false)
        }
        return (String(localized: "Standort nicht geteilt"), false)
    }

    private var myStatus: String? {
        guard let here = app.location.lastLocation?.coordinate else { return nil }
        let d = here.distance(to: meetup.coordinate)
        if d < 150 { return String(localized: "Du bist da") }
        if app.navigation.isNavigating, let dest = app.navigation.destination,
           dest.coordinate.distance(to: meetup.coordinate) < 300, let eta = app.navigation.eta {
            return String(localized: "Du bist an \(Format.time.string(from: eta))")
        }
        return String(localized: "Du: \(Format.distance(d)) entfernt")
    }

    private var recentMessages: [MessagesStore.Message] {
        let ids = Set(participants.map(\.id))
        let ids2 = Set(entry.meetups.map(\.id))
        return app.messages.messages
            .filter { ($0.meetupId.map(ids2.contains) ?? false) || ids.contains($0.otherId) }
            .prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meetup.placeName).font(Theme.title(17)).foregroundStyle(Theme.text)
                    if let at = meetup.meetAt {
                        Label(Meetup.timeText(at), systemImage: "clock").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    }
                    Text(entry.accepted ? String(localized: "Zugesagt") : (meetup.incoming ? String(localized: "Einladung an dich") : String(localized: "Wartet auf Zusage")))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(entry.accepted ? Theme.accent : Theme.muted)
                }
                Spacer()
                Button { navigate(meetup.place) } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.title2).foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.accent))
                }
                .accessibilityLabel("Zum Treffpunkt navigieren")
            }

            if let myStatus {
                Text(myStatus).font(.footnote).foregroundStyle(Theme.muted)
            }

            VStack(spacing: 8) {
                ForEach(participants) { p in
                    HStack(spacing: 10) {
                        Avatar(initials: initials(p.name), color: FriendPalette.color(for: p.id), size: 32,
                               faded: !p.accepted, userId: p.id)
                        Text(p.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        if p.arrived {
                            Label("ist da", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.bold)).foregroundStyle(Theme.go)
                        } else {
                            Text(p.status).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
            }

            if !recentMessages.isEmpty {
                Divider().overlay(Theme.stroke)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recentMessages) { m in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(m.incoming ? m.firstName : "Du").font(.caption.weight(.bold))
                                .foregroundStyle(m.incoming ? Theme.text : Theme.accent)
                            Text(m.body).font(.caption).foregroundStyle(Theme.text)
                            Spacer(minLength: 4)
                            Text(Format.time.string(from: m.createdAt)).font(.caption2).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }

            if entry.accepted {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MessagesStore.quickReplies(eta: myEta), id: \.self) { text in
                            Button(text) { send(text) }
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Capsule().fill(Theme.panelRaised))
                                .foregroundStyle(Theme.text)
                                .disabled(sending)
                        }
                    }
                }
            } else if meetup.incoming {
                HStack {
                    Button("Zusagen") { Task { await app.meetups.respond(meetup, accept: true) } }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Ablehnen") { Task { await app.meetups.respond(meetup, accept: false) } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
        .task(id: meetup.groupId) {
            if let gid = meetup.groupId { members = await app.meetups.groupMembers(gid) }
        }
    }

    private var myEta: Date? {
        guard app.navigation.isNavigating, let dest = app.navigation.destination,
              dest.coordinate.distance(to: meetup.coordinate) < 300 else { return nil }
        return app.navigation.eta
    }

    private func send(_ text: String) {
        let ids = participants.filter(\.accepted).map(\.id)
        guard !ids.isEmpty else { return }
        sending = true
        Task {
            let n = await app.messages.send(text, to: ids, meetupId: entry.meetups.first(where: \.isAccepted)?.id)
            sending = false
            app.show(n > 0 ? String(localized: "Gesendet") : String(localized: "Nachricht nicht gesendet"), isError: n == 0)
        }
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
