import Foundation
import ActivityKit
import UIKit
import CoreLocation

/// Treffen auf dem Sperrbildschirm und in der Dynamic Island: Ab zwei Stunden vor der verabredeten Zeit (bzw. bei
/// „jetzt“-Treffen ab der Zusage) zeigt Meeterz, wo die anderen sind und wann sie ankommen. Endet eine Stunde nach
/// der Zeit, wenn alle da sind oder das Treffen nicht mehr gilt.
@MainActor
final class MeetupLiveActivityController {
    static let shared = MeetupLiveActivityController()

    private var activity: Activity<MeetupActivityAttributes>?
    private var meetupKey: String?
    private var lastState: MeetupActivityAttributes.ContentState?
    private var allHereSince: Date?
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { MeetupLiveActivityController.shared.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        end()
    }

    func refresh() {
        let app = AppModel.shared
        guard let (meetup, group) = currentMeetup(app) else { end(); return }
        let place = meetup.coordinate
        let ids = Set(group.map(\.otherId))
        let members: [MeetupActivityAttributes.Member] = ids.compactMap { id in
            guard let friend = app.friend(id) else { return nil }
            let first = friend.firstName
            let position = app.hub.positions[id]
            let distance = position.map { $0.coordinate.distance(to: place) }
            return .init(name: first, initials: friend.initials, distance: distance, eta: app.routes.route(of: id, to: place)?.eta, here: (distance ?? .infinity) < 150)
        }
        .sorted { ($0.here ? 1 : 0, $0.eta ?? .distantFuture) < ($1.here ? 1 : 0, $1.eta ?? .distantFuture) }
        guard !members.isEmpty else { end(); return }

        // Alle da: noch 15 Minuten zeigen, dann beenden
        if members.allSatisfy(\.here) {
            if allHereSince == nil { allHereSince = Date() }
            if Date().timeIntervalSince(allHereSince!) > 15 * 60 { end(); return }
        } else { allHereSince = nil }

        let key = meetup.groupId?.uuidString ?? meetup.id.uuidString
        let state = MeetupActivityAttributes.ContentState(members: Array(members.prefix(4)))
        if activity == nil || meetupKey != key {
            end()
            // Starten geht nur mit der App im Vordergrund; Aktualisieren auch im Hintergrund
            guard UIApplication.shared.applicationState == .active, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                activity = try Activity.request(
                    attributes: MeetupActivityAttributes(placeName: meetup.placeName, meetAt: meetup.meetAt),
                    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60)), pushType: nil)
                meetupKey = key
                lastState = state
                Diag.log("Live-Aktivität Treffen gestartet: \(meetup.placeName)")
            } catch {
                Diag.log("Live-Aktivität Treffen konnte nicht starten: \(error.localizedDescription)")
            }
            return
        }
        guard state != lastState, let activity else { return }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10 * 60))) }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        meetupKey = nil
        lastState = nil
        allHereSince = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Nächstes zugesagtes Treffen im Zeitfenster (samt den übrigen Einladungen derselben Gruppe)
    private func currentMeetup(_ app: AppModel) -> (Meetup, [Meetup])? {
        let now = Date()
        let accepted = app.meetups.meetups.filter(\.isAccepted)
        let candidates = accepted.filter { m in
            if let at = m.meetAt { return at.timeIntervalSince(now) < 2 * 3600 && now.timeIntervalSince(at) < 3600 }
            return now.timeIntervalSince(m.createdAt) < 3 * 3600
        }
        guard let next = candidates.min(by: { ($0.meetAt ?? $0.createdAt) < ($1.meetAt ?? $1.createdAt) }) else { return nil }
        let group = next.groupId.map { g in accepted.filter { $0.groupId == g } } ?? [next]
        return (next, group)
    }
}
