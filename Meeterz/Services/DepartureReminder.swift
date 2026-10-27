import Foundation
import UserNotifications
import CoreLocation
import MapboxDirections

/// „In 10 Min. losfahren“: Für angenommene Treffen mit Uhrzeit die Abfahrtszeit aus Fahrzeit mit Verkehr
/// (zum Treffzeitpunkt), Routenoptionen und – beim E-Auto – Ladestopps berechnen und eine Mitteilung planen.
///
/// Die Fahrzeit wird nachgerechnet, solange die App läuft (bei jeder Aktualisierung der Treffen, höchstens alle
/// 10 Minuten; weiter entfernte Treffen stündlich). Die Mitteilung selbst stellt iOS zu – auch wenn die App zu ist.
@MainActor
final class DepartureReminder {
    static let shared = DepartureReminder()

    /// Vorlauf der Mitteilung vor der Abfahrt
    static let lead: TimeInterval = 10 * 60
    /// Puffer fürs Parken/Ankommen
    static let buffer: TimeInterval = 5 * 60

    private var running = false
    private var lastRun = Date.distantPast
    private var lastIds: Set<UUID> = []
    private var lastCalc: [UUID: Date] = [:]
    /// Bereits zugestellte „Jetzt losfahren“-Meldungen (nicht doppelt)
    private var firedNow: Set<UUID> {
        get { Set((UserDefaults.standard.array(forKey: "depart.fired") as? [String] ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: "depart.fired") }
    }

    func refresh() async {
        let upcoming = AppModel.shared.meetups.accepted.filter {
            guard let at = $0.meetAt else { return false }
            return at > Date() && at < Date().addingTimeInterval(24 * 3600)
        }
        let ids = Set(upcoming.map(\.id))
        let setChanged = ids != lastIds
        guard !running, setChanged || Date().timeIntervalSince(lastRun) > 10 * 60 else { return }
        running = true
        defer { running = false }
        lastRun = Date()
        lastIds = ids

        let center = UNUserNotificationCenter.current()
        // Erinnerungen für abgesagte/vergangene Treffen entfernen
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("depart-") }
        let keep = Set(upcoming.map { "depart-\($0.id)" })
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !keep.contains($0) })

        for meetup in upcoming {
            guard let at = meetup.meetAt else { continue }
            // Weit entfernte Treffen nur stündlich nachrechnen (spart Routenanfragen)
            let far = at.timeIntervalSinceNow > 4 * 3600
            if far, let last = lastCalc[meetup.id], Date().timeIntervalSince(last) < 3600, !setChanged { continue }
            // Schon unterwegs dorthin: keine Erinnerung
            if let dest = AppModel.shared.navigation.destination, AppModel.shared.navigation.isNavigating,
               dest.coordinate.distance(to: meetup.coordinate) < 300 {
                center.removePendingNotificationRequests(withIdentifiers: ["depart-\(meetup.id)"])
                continue
            }
            guard let trip = await travel(to: meetup, departingBy: at) else { continue }
            lastCalc[meetup.id] = Date()
            let depart = at.addingTimeInterval(-trip.duration - Self.buffer)
            let fire = depart.addingTimeInterval(-Self.lead)
            let minutes = Int((trip.duration / 60).rounded())
            let extra = trip.chargeStops > 0 ? (trip.chargeStops == 1 ? String(localized: " inkl. 1 Ladestopp") : String(localized: " inkl. \(trip.chargeStops) Ladestopps")) : ""
            let body = String(localized: "Um \(Meetup.timeText(at)) bei \(meetup.withText) (\(meetup.placeName)) · ca. \(minutes) Min. Fahrt\(extra)")

            if fire > Date().addingTimeInterval(30) {
                schedule(meetup, title: String(localized: "In 10 Min. losfahren"), body: body, at: fire)
            } else if !firedNow.contains(meetup.id) {
                // Zu spät für den Vorlauf: sofort melden
                let late = Date() > depart ? Int((Date().timeIntervalSince(depart) / 60).rounded()) : 0
                let title = late > 2 ? String(localized: "Jetzt losfahren – ca. \(late) Min. zu spät") : String(localized: "Jetzt losfahren")
                schedule(meetup, title: title, body: body, at: nil)
                firedNow.insert(meetup.id)
            }
            Diag.log("Losfahren-Erinnerung \(meetup.placeName): Abfahrt \(depart.formatted(date: .omitted, time: .shortened)) (\(minutes) Min.\(extra))")
        }
        // Alte „schon gemeldet“-Einträge aufräumen
        firedNow = firedNow.intersection(Set(AppModel.shared.meetups.meetups.map(\.id)))
    }

    private struct Trip { let duration: TimeInterval; let chargeStops: Int }

    /// Fahrzeit mit Verkehr zur Abfahrtszeit (geschätzt), beim E-Auto plus Ladezeit
    private func travel(to meetup: Meetup, departingBy at: Date) async -> Trip? {
        // Grobe Abfahrt für die Verkehrsprognose: 30 Min. vorher (genauer wird es beim Nachrechnen)
        let departure = at.addingTimeInterval(-30 * 60)
        guard let route = await AppModel.shared.navigation.driveRoute(to: meetup.coordinate,
                                                                     departing: departure > Date().addingTimeInterval(15 * 60) ? departure : nil)
        else { return nil }
        var duration = route.expectedTravelTime
        var stops = 0
        if EVSettings.enabled, EVSettings.vehicle != nil, case .success(let plan)? = await EVSettings.plan(for: route), !plan.direct {
            stops = plan.stops.count
            duration += plan.totalChargeTime + Double(stops) * 5 * 60   // An- und Abfahrt an der Säule
        }
        return Trip(duration: duration, chargeStops: stops)
    }

    private func schedule(_ meetup: Meetup, title: String, body: String, at date: Date?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["type": "depart", "meetup": meetup.id.uuidString]
        let trigger = date.map {
            UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0),
                                          repeats: false)
        }
        // Gleiche ID: ersetzt die bisher geplante Erinnerung mit der neuen Zeit
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "depart-\(meetup.id)", content: content, trigger: trigger))
    }

    /// Tipp auf die Mitteilung: Route zum Treffpunkt öffnen
    func open(meetupId: String) async {
        guard let meetup = AppModel.shared.meetups.meetups.first(where: { $0.id.uuidString == meetupId }) else { return }
        await AppModel.shared.navigation.planRoute(to: meetup.place, mode: .car)
    }
}
