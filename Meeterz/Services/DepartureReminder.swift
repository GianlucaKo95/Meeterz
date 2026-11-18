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

    /// Selbst geplante Fahrt („Ankunft um …“ / „Abfahrt ab …“ in der Routenvorschau) – nur auf dem Gerät.
    /// `at` = gewünschte Ankunft, bei `leave` die gewählte Abfahrt
    struct PlannedArrival: Codable, Identifiable {
        var id = UUID()
        let name: String
        let address: String?
        let lat: Double, lng: Double
        let at: Date
        var leave: Bool? = nil
        var place: Place { Place(id: "arrive-\(id)", name: name, address: address, coordinate: .init(latitude: lat, longitude: lng)) }
    }

    var planned: [PlannedArrival] {
        get { (UserDefaults.standard.data(forKey: "depart.planned")).flatMap { try? JSONDecoder().decode([PlannedArrival].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "depart.planned") }
    }

    /// „Ankunft um …“ bzw. „Abfahrt ab …“ (`leave`): Ziel merken und die Losfahren-Erinnerung planen
    /// (ersetzt eine frühere Planung zum selben Ziel)
    func plan(_ place: Place, at: Date, leave: Bool) async {
        planned = planned.filter { $0.at > Date() && $0.place.coordinate.distance(to: place.coordinate) > 150 }
            + [PlannedArrival(name: place.name, address: place.address, lat: place.coordinate.latitude, lng: place.coordinate.longitude,
                              at: at, leave: leave)]
        await refresh()
    }

    func cancelPlan(_ id: UUID) {
        planned.removeAll { $0.id == id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["depart-\(id)"])
    }

    /// Was erinnert wird: Treffen mit Uhrzeit und selbst geplante Ankünfte
    private struct Target {
        let id: UUID
        let place: Place
        let at: Date
        /// `at` ist die Abfahrt (statt der Ankunft)
        var leave = false
        /// `other`: berechnete Abfahrt bzw. bei `leave` die Ankunft
        let text: (_ minutes: Int, _ extra: String, _ other: Date) -> String
    }

    func refresh() async {
        planned = planned.filter { $0.at > Date() }
        let meetups = AppModel.shared.meetups.accepted.filter {
            guard let at = $0.meetAt else { return false }
            return at > Date() && at < Date().addingTimeInterval(24 * 3600)
        }
        let upcoming = meetups.map { m in
            Target(id: m.id, place: m.place, at: m.meetAt!) { minutes, extra, _ in
                String(localized: "Um \(Meetup.timeText(m.meetAt!)) bei \(m.withText) (\(m.placeName)) · ca. \(minutes) Min. Fahrt\(extra)")
            }
        } + planned.filter { $0.at < Date().addingTimeInterval(24 * 3600) }.map { p in
            p.leave == true
                ? Target(id: p.id, place: p.place, at: p.at, leave: true) { minutes, extra, arrival in
                    String(localized: "Abfahrt \(Meetup.timeText(p.at)) nach \(p.name) · Ankunft ca. \(arrival.formatted(date: .omitted, time: .shortened)) (\(minutes) Min.\(extra))")
                }
                : Target(id: p.id, place: p.place, at: p.at) { minutes, extra, _ in
                    String(localized: "Ankunft um \(Meetup.timeText(p.at)) in \(p.name) · ca. \(minutes) Min. Fahrt\(extra)")
                }
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

        for target in upcoming {
            let at = target.at
            // Weit entfernte Treffen nur stündlich nachrechnen (spart Routenanfragen)
            let far = at.timeIntervalSinceNow > 4 * 3600
            if far, let last = lastCalc[target.id], Date().timeIntervalSince(last) < 3600, !setChanged { continue }
            // Schon unterwegs dorthin: keine Erinnerung
            if let dest = AppModel.shared.navigation.destination, AppModel.shared.navigation.isNavigating,
               dest.coordinate.distance(to: target.place.coordinate) < 300 {
                center.removePendingNotificationRequests(withIdentifiers: ["depart-\(target.id)"])
                continue
            }
            guard let trip = target.leave ? await travel(to: target.place.coordinate, departingAt: at)
                                          : await travel(to: target.place.coordinate, arrivingBy: at) else { continue }
            lastCalc[target.id] = Date()
            let depart = target.leave ? at : at.addingTimeInterval(-trip.duration - Self.buffer)
            let fire = depart.addingTimeInterval(-Self.lead)
            let minutes = Int((trip.duration / 60).rounded())
            let extra = trip.chargeStops > 0 ? (trip.chargeStops == 1 ? String(localized: " inkl. 1 Ladestopp") : String(localized: " inkl. \(trip.chargeStops) Ladestopps")) : ""
            let body = target.text(minutes, extra, target.leave ? at.addingTimeInterval(trip.duration) : depart)

            if fire > Date().addingTimeInterval(30) {
                schedule(target, title: String(localized: "In 10 Min. losfahren"), body: body, at: fire)
            } else if !firedNow.contains(target.id) {
                // Zu spät für den Vorlauf: sofort melden
                let late = Date() > depart ? Int((Date().timeIntervalSince(depart) / 60).rounded()) : 0
                let title = late > 2 ? String(localized: "Jetzt losfahren – ca. \(late) Min. zu spät") : String(localized: "Jetzt losfahren")
                schedule(target, title: title, body: body, at: nil)
                firedNow.insert(target.id)
            }
            Diag.log("Losfahren-Erinnerung \(target.place.name): Abfahrt \(depart.formatted(date: .omitted, time: .shortened)) (\(minutes) Min.\(extra))")
        }
        // Alte „schon gemeldet“-Einträge aufräumen
        firedNow = firedNow.intersection(Set(AppModel.shared.meetups.meetups.map(\.id) + planned.map(\.id)))
    }

    /// Abfahrtszeit für „Ankunft um …“ (übliche Verkehrslage zu dieser Zeit, beim E-Auto mit Ladestopps, plus Puffer)
    func departure(to place: Place, arriveAt: Date) async -> Date? {
        guard let trip = await travel(to: place.coordinate, arrivingBy: arriveAt) else { return nil }
        return arriveAt.addingTimeInterval(-trip.duration - Self.buffer)
    }

    /// Ankunftszeit für „Abfahrt ab …“ (übliche Verkehrslage zur gewählten Abfahrt, beim E-Auto mit Ladestopps)
    func arrival(to place: Place, departAt: Date) async -> Date? {
        guard let trip = await travel(to: place.coordinate, departingAt: departAt) else { return nil }
        return departAt.addingTimeInterval(trip.duration)
    }

    private struct Trip { let duration: TimeInterval; let chargeStops: Int }

    /// Fahrzeit bei Abfahrt `at` mit der für diese Uhrzeit üblichen Verkehrslage (Mapbox `depart_at`, Prognose aus
    /// historischen Daten); liegt `at` in den nächsten Minuten, der aktuelle Verkehr. Beim E-Auto plus Ladezeit.
    private func travel(to coordinate: CLLocationCoordinate2D, departingAt at: Date) async -> Trip? {
        let when = at > Date().addingTimeInterval(5 * 60) ? at : nil
        guard let route = await AppModel.shared.navigation.driveRoute(to: coordinate, departing: when) else { return nil }
        var duration = route.expectedTravelTime
        var stops = 0
        if EVSettings.enabled, EVSettings.vehicle != nil, case .success(let plan)? = await EVSettings.plan(for: route), !plan.direct {
            stops = plan.stops.count
            duration += plan.totalChargeTime + Double(stops) * 5 * 60   // An- und Abfahrt an der Säule
        }
        return Trip(duration: duration, chargeStops: stops)
    }

    /// Fahrzeit für Ankunft um `at`: Die Abfahrt hängt vom Verkehr ab und der Verkehr von der Abfahrt – darum mit
    /// einer Schätzung beginnen und mit der Prognose für die so berechnete Abfahrt höchstens zweimal nachrechnen.
    private func travel(to coordinate: CLLocationCoordinate2D, arrivingBy at: Date) async -> Trip? {
        guard var trip = await travel(to: coordinate, departingAt: at.addingTimeInterval(-30 * 60)) else { return nil }
        for _ in 0..<2 {
            let depart = at.addingTimeInterval(-trip.duration - Self.buffer)
            guard let next = await travel(to: coordinate, departingAt: depart) else { break }
            let settled = abs(next.duration - trip.duration) < 60
            trip = next
            if settled { break }
        }
        return trip
    }

    private func schedule(_ target: Target, title: String, body: String, at date: Date?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["type": "depart", "meetup": target.id.uuidString]
        let trigger = date.map {
            UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0),
                                          repeats: false)
        }
        // Gleiche ID: ersetzt die bisher geplante Erinnerung mit der neuen Zeit
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "depart-\(target.id)", content: content, trigger: trigger))
    }

    /// Tipp auf die Mitteilung: Route zum Treffpunkt öffnen
    func open(meetupId: String) async {
        if let p = planned.first(where: { $0.id.uuidString == meetupId }) {
            await AppModel.shared.navigation.planRoute(to: p.place, mode: .car)
            return
        }
        guard let meetup = AppModel.shared.meetups.meetups.first(where: { $0.id.uuidString == meetupId }) else { return }
        await AppModel.shared.navigation.planRoute(to: meetup.place, mode: .car)
    }
}
