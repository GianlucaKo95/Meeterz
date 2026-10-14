import SwiftUI
import CoreLocation

// MARK: - Karten über dem Unterwegs-Panel: Vorschläge, Zusagen, Gelegenheiten

struct SocialCards: View {
    @Environment(AppModel.self) private var app
    @Binding var plannedMeetup: MeetupCandidate?

    var body: some View {
        VStack(spacing: 10) {
            if let incoming = app.meetups.incomingPending.first {
                IncomingMeetupCard(meetup: incoming)
            } else if let accepted = app.meetups.accepted.first {
                AcceptedMeetupCard(meetup: accepted)
            } else if let waiting = app.meetups.outgoingPending.first {
                WaitingCard(meetup: waiting)
            } else if let candidate = app.meetups.visibleCandidates.first,
                      let friend = app.friend(candidate.friendId) {
                CandidateCard(candidate: candidate, friend: friend) { plannedMeetup = candidate }
            }
        }
        .animation(.snappy, value: app.meetups.meetups)
    }
}

private struct CandidateCard: View {
    @Environment(AppModel.self) private var app
    let candidate: MeetupCandidate
    let friend: FriendRow
    let plan: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                Avatar(initials: friend.initials, color: FriendPalette.color(for: friend.friendId), userId: friend.friendId)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(friend.displayName) kreuzt deinen Weg").font(Theme.title(16))
                    Text("In \(Format.minutes(until: max(candidate.myEta, candidate.friendEta))) seid ihr nah beieinander")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { app.meetups.dismiss(candidate) } label: { Image(systemName: "xmark") }
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("Ausblenden")
            }
            Button("Treffen planen", action: plan).buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct IncomingMeetupCard: View {
    @Environment(AppModel.self) private var app
    let meetup: Meetup

    var body: some View {
        Card {
            Text("\(meetup.otherName) möchte sich treffen")
                .font(.caption.weight(.bold)).foregroundStyle(Theme.accent).textCase(.uppercase)
            Text(meetup.placeName).font(Theme.display(22))
            HStack(spacing: 10) {
                Button("Ablehnen") { Task { await app.meetups.respond(meetup, accept: false) } }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Annehmen") {
                    Task {
                        await app.meetups.respond(meetup, accept: true)
                        await app.navigation.addStop(meetup.place)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

private struct AcceptedMeetupCard: View {
    @Environment(AppModel.self) private var app
    let meetup: Meetup

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Treffen mit \(meetup.otherName)")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.accent).textCase(.uppercase)
                    Text(meetup.placeName).font(Theme.title(18))
                }
                Spacer()
                Menu {
                    Button("Treffen absagen", systemImage: "xmark.circle", role: .destructive) {
                        Task { await app.meetups.cancel(meetup) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Optionen")
            }
            Button(app.navigation.isNavigating ? "Als Zwischenstopp" : "Hinfahren") {
                Task { await app.navigation.addStop(meetup.place) }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct WaitingCard: View {
    @Environment(AppModel.self) private var app
    let meetup: Meetup

    var body: some View {
        Card {
            HStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Warte auf \(meetup.otherName)").font(Theme.title(15))
                    Text(meetup.placeName).font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Zurückziehen") { Task { await app.meetups.cancel(meetup) } }
                    .font(.footnote.weight(.semibold))
            }
        }
    }
}

// MARK: - Treffen planen

struct MeetupPlannerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let candidate: MeetupCandidate

    @State private var category: SearchService.Category = .restArea
    @State private var places: [Place] = []
    @State private var selected: Place?
    @State private var loading = false
    @State private var errorText: String?
    @State private var sending = false

    private var exactSpot: Place {
        Place(id: "spot", name: "Treffpunkt auf der Route", address: nil, coordinate: candidate.coordinate)
    }

    var body: some View {
        let friend = app.friend(candidate.friendId)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    if let friend {
                        Avatar(initials: friend.initials, color: FriendPalette.color(for: friend.friendId), size: 48, userId: friend.friendId)
                    }
                    VStack(alignment: .leading) {
                        Text("Treffen mit \(friend?.displayName ?? "Freund")").font(Theme.display(24))
                        Text("Eure Wege kreuzen sich").foregroundStyle(Theme.muted)
                    }
                }

                HStack(spacing: 10) {
                    TimeTile(title: "Du", value: Format.time.string(from: candidate.myEta), highlight: true)
                    TimeTile(title: friend?.displayName ?? "Freund", value: Format.time.string(from: candidate.friendEta))
                    TimeTile(title: "Abstand", value: Format.distance(candidate.distanceM))
                }

                Text("Wo wollt ihr euch treffen?").font(Theme.title())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SearchService.Category.allCases) { c in
                            Button(c.title) { category = c }
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(Capsule().fill(category == c ? Theme.text : .clear))
                                .overlay(Capsule().stroke(Theme.stroke))
                                .foregroundStyle(category == c ? Theme.ink : Theme.text)
                        }
                    }
                }

                VStack(spacing: 8) {
                    PlaceRow(place: exactSpot, distance: nil, selected: selected == exactSpot) { selected = exactSpot }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.muted) }
                    ForEach(places) { place in
                        PlaceRow(place: place,
                                 distance: place.coordinate.distance(to: candidate.coordinate),
                                 selected: selected == place) { selected = place }
                    }
                }

                Button(sending ? "Wird gesendet …" : "Treffen vorschlagen") {
                    guard let selected else { return }
                    Task {
                        sending = true
                        if await app.meetups.propose(to: candidate.friendId, place: selected) {
                            app.show("Vorschlag an \(friend?.displayName ?? "Freund") gesendet.", isError: false)
                            dismiss()
                        }
                        sending = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected == nil || sending)
                .opacity(selected == nil ? 0.5 : 1)
            }
            .padding(20)
        }
        .background(Theme.ink)
        .presentationDetents([.large])
        .task(id: category) { await loadPlaces() }
    }

    private func loadPlaces() async {
        loading = true
        errorText = nil
        do {
            places = try await SearchService.places(category, near: candidate.coordinate)
            if places.isEmpty { errorText = "Keine passenden Orte in der Nähe." }
        } catch {
            places = []
            errorText = error.localizedDescription
        }
        loading = false
    }
}

private struct TimeTile: View {
    let title: String
    let value: String
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            Text(value).font(Theme.display(20)).foregroundStyle(highlight ? Theme.accent : Theme.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelRaised))
    }
}

struct PlaceRow: View {
    let place: Place
    let distance: Double?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "mappin.circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(Theme.title(15)).foregroundStyle(Theme.text)
                    if let address = place.address {
                        Text(address).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer()
                if let distance {
                    Text(Format.distance(distance)).font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(selected ? Theme.panelRaised : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Theme.accent : Theme.stroke))
        }
    }
}


// MARK: - Zu einem Ort einladen

/// Freunde zu einem beliebigen Ziel einladen (mehrere auf einmal).
struct InviteFriendsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let place: Place
    /// Vorausgewählter Freund (Einstieg über die Freundesliste)
    var preselected: UUID?

    @State private var selected: Set<UUID> = []
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Einladen nach").font(.caption.weight(.bold)).foregroundStyle(Theme.accent).textCase(.uppercase)
                Text(place.name).font(Theme.display(24))
                if let address = place.address { Text(address).foregroundStyle(Theme.muted) }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(app.friends.accepted) { row in
                        let on = selected.contains(row.friendId)
                        Button {
                            if on { selected.remove(row.friendId) } else { selected.insert(row.friendId) }
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(initials: row.initials, color: FriendPalette.color(for: row.friendId), userId: row.friendId)
                                Text(row.displayName).font(Theme.title(16)).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(on ? Theme.accent : Theme.muted)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(on ? Theme.panelRaised : Theme.panel))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? Theme.accent : Theme.stroke))
                        }
                    }
                }
            }

            Text("Die Eingeladenen können zusagen oder ablehnen. Bei einer Zusage wird der Ort bei ihnen als Ziel vorgeschlagen.")
                .font(.footnote).foregroundStyle(Theme.muted)

            Button(sending ? "Wird gesendet …" : "Einladung senden") {
                Task {
                    sending = true
                    var sent = 0
                    for id in selected where await app.meetups.propose(to: id, place: place, silent: true) {
                        sent += 1
                    }
                    sending = false
                    if sent > 0 {
                        app.show(sent == 1 ? "Einladung gesendet." : "\(sent) Einladungen gesendet.", isError: false)
                        dismiss()
                    } else {
                        app.show("Einladung konnte nicht gesendet werden.")
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selected.isEmpty || sending)
            .opacity(selected.isEmpty ? 0.5 : 1)
        }
        .padding(20)
        .background(Theme.ink)
        .presentationDetents([.medium, .large])
        .onAppear { if let preselected { selected = [preselected] } }
    }
}
