import Foundation
import CoreLocation
import EventKit
import MapboxDirections
import MapboxNavigationCore

/// Routenvorschlag wie bei Apple Karten: EIN Ziel, das jetzt wahrscheinlich ist – ein Kalendertermin mit Ort, zu dem man
/// bald losfahren muss, sonst ein Ort, den man um diese Zeit an diesem Wochentag oft ansteuert.
///
/// Die „wichtigen Orte“ von iOS sind für Apps nicht zugänglich. Meeterz lernt deshalb selbst: iOS meldet Aufenthalte
/// (CLVisit, stromsparend, auch im Hintergrund). Alles bleibt auf dem iPhone, nichts geht an den Server.
@MainActor
final class RouteSuggestions {
    static let shared = RouteSuggestions()

    struct Suggestion: Equatable {
        enum Reason: Equatable { case calendar(title: String, start: Date), frequent }
        let place: Place
        let reason: Reason
        /// Fahrzeit jetzt (s)
        let travelTime: TimeInterval
        var arrival: Date { Date().addingTimeInterval(travelTime) }

        /// „Arbeit“ bzw. Termintitel
        var title: String {
            if case .calendar(let title, _) = reason { return title }
            return place.name
        }
        /// „24 Min. · Termin 09:00“ bzw. „24 Min. · Ankunft 08:12“
        var subtitle: String {
            let minutes = String(localized: "\(max(1, Int((travelTime / 60).rounded()))) Min.")
            if case .calendar(_, let start) = reason {
                return minutes + " · " + String(localized: "Termin \(Format.time.string(from: start))")
            }
            return minutes + " · " + String(localized: "Ankunft \(Format.time.string(from: arrival))")
        }
    }

    /// Zuletzt ermittelter Vorschlag (für die Dashboard-Schnellwahl)
    private(set) var current: Suggestion?
    private var computedAt = Date.distantPast
    private var computing: Task<Suggestion?, Never>?

    // MARK: Einstellungen

    static let frequentKey = "suggest.frequent"
    static let calendarKey = "suggest.calendar"
    static var frequentEnabled: Bool {
        get { UserDefaults.standard.object(forKey: frequentKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: frequentKey) }
    }
    static var calendarEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: calendarKey) }
        set { UserDefaults.standard.set(newValue, forKey: calendarKey) }
    }

    // MARK: Ermitteln

    /// Vorschlag für jetzt (höchstens alle 5 Minuten neu berechnet)
    func refresh(force: Bool = false) async -> Suggestion? {
        if !force, Date().timeIntervalSince(computedAt) < 5 * 60 { return current }
        if let computing { return await computing.value }
        let task = Task { @MainActor in await self.compute() }
        computing = task
        let result = await task.value
        computing = nil
        computedAt = Date()
        if result != current {
            current = result
            Diag.log(result.map { "Routenvorschlag: \($0.title) – \($0.subtitle)" } ?? "Routenvorschlag: keiner")
            CarPlayDashboard.shared.updateShortcuts()
        }
        return result
    }

    private func compute() async -> Suggestion? {
        guard let here = AppModel.shared.location.lastLocation else { return nil }
        if Self.calendarEnabled, let s = await calendarSuggestion(from: here) { return s }
        if Self.frequentEnabled, let s = await frequentSuggestion(from: here) { return s }
        return nil
    }

    // MARK: Kalender

    private let store = EKEventStore()
    private var geocoded: [String: CLLocationCoordinate2D] = [:]

    /// Kalenderzugriff anfragen (beim Einschalten in den Einstellungen)
    func requestCalendarAccess() async -> Bool {
        do { return try await store.requestFullAccessToEvents() } catch { return false }
    }

    var calendarAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Termin mit Ort, zu dem man in spätestens 30 Minuten losfahren muss (Fahrzeit + 5 Min. Puffer)
    private func calendarSuggestion(from here: CLLocation) async -> Suggestion? {
        guard calendarAuthorized else { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-10 * 60), end: now.addingTimeInterval(6 * 3600),
                                                 calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(-10 * 60) }
            .sorted { $0.startDate < $1.startDate }
        for event in events.prefix(5) {
            guard let coordinate = await coordinate(of: event),
                  here.coordinate.distance(to: coordinate) > 300 else { continue }
            // Grob vorsortieren (Luftlinie mit 40 km/h), bevor eine Route angefragt wird
            let rough = here.coordinate.distance(to: coordinate) / (40 / 3.6)
            guard event.startDate.timeIntervalSince(now) - rough < 3 * 3600 else { continue }
            let name = event.structuredLocation?.title?.split(separator: "\n").first.map(String.init) ?? event.location ?? event.title ?? ""
            let place = Place(id: "event-\(event.eventIdentifier ?? UUID().uuidString)", name: name, address: event.location,
                              coordinate: coordinate)
            guard let travel = await travelTime(to: coordinate, from: here) else { continue }
            let leave = event.startDate.addingTimeInterval(-travel - 5 * 60)
            guard leave.timeIntervalSince(now) <= 30 * 60 else { continue }   // noch zu früh
            return Suggestion(place: place, reason: .calendar(title: event.title ?? name, start: event.startDate), travelTime: travel)
        }
        return nil
    }

    private func coordinate(of event: EKEvent) async -> CLLocationCoordinate2D? {
        if let geo = event.structuredLocation?.geoLocation { return geo.coordinate }
        guard let text = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let cached = geocoded[text] { return cached }
        // Online-Termine haben oft nur einen Link als Ort
        if text.contains("http") || text.lowercased().contains("teams") || text.lowercased().contains("zoom") { return nil }
        guard let placemark = try? await CLGeocoder().geocodeAddressString(text).first,
              let coordinate = placemark.location?.coordinate else { return nil }
        geocoded[text] = coordinate
        return coordinate
    }

    // MARK: Häufige Orte

    private func frequentSuggestion(from here: CLLocation) async -> Suggestion? {
        guard let spot = FrequentPlaces.shared.likelyDestination(now: Date(), from: here.coordinate) else { return nil }
        guard let travel = await travelTime(to: spot.coordinate, from: here) else { return nil }
        return Suggestion(place: spot.place, reason: .frequent, travelTime: travel)
    }

    // MARK: Fahrzeit

    private var travelCache: [String: (time: TimeInterval, at: Date)] = [:]

    private func travelTime(to coordinate: CLLocationCoordinate2D, from here: CLLocation) async -> TimeInterval? {
        let key = String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        if let c = travelCache[key], Date().timeIntervalSince(c.at) < 5 * 60 { return c.time }
        let options = NavigationRouteOptions(
            waypoints: [Waypoint(location: here, name: nil), Waypoint(coordinate: coordinate, name: nil)],
            profileIdentifier: .automobileAvoidingTraffic, locale: Locale.navigation, distanceUnit: .kilometer)
        RoutePreferences.apply(to: options)
        let provider = navigationProvider.mapboxNavigation.routingProvider()
        guard let routes = try? await provider.calculateRoutes(options: options).value else { return nil }
        let time = routes.mainRoute.route.expectedTravelTime
        travelCache[key] = (time, Date())
        return time
    }
}

/// Selbst gelernte häufige Ziele: Aufenthalte (iOS-Besuche) werden zu Orten zusammengefasst, je Ort mit den Ankunftszeiten.
/// Vorhersage: Orte, an denen man an diesem Wochentag (bzw. Werktag/Wochenende) um diese Zeit oft ankommt.
@MainActor
final class FrequentPlaces {
    static let shared = FrequentPlaces()

    struct Spot: Codable, Identifiable, Sendable {
        var id = UUID()
        var lat: Double
        var lng: Double
        var name: String?
        var arrivals: [Date] = []
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
        var place: Place {
            Place(id: "frequent-\(id.uuidString)", name: name ?? String(localized: "Häufiger Ort"), address: nil, coordinate: coordinate)
        }
    }

    private(set) var spots: [Spot] = []
    private static let radius: CLLocationDistance = 150
    private static let maxSpots = 150
    private static let maxArrivals = 80

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("frequent-places.json")
    }

    init() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Spot].self, from: data) { spots = list }
    }

    /// Aufenthalt von iOS (nur die Ankunft zählt; Abfahrtsmeldungen derselben Ankunft werden zusammengeführt)
    func record(coordinate: CLLocationCoordinate2D, accuracy: CLLocationAccuracy, arrival: Date) {
        guard RouteSuggestions.frequentEnabled, accuracy >= 0, accuracy < 250,
              arrival > Date.distantPast.addingTimeInterval(1), arrival < Date().addingTimeInterval(60) else { return }
        let index: Int
        if let i = spots.firstIndex(where: { $0.coordinate.distance(to: coordinate) < Self.radius }) {
            index = i
            // Dieselbe Ankunft kommt mit der Abfahrt noch einmal
            if spots[i].arrivals.contains(where: { abs($0.timeIntervalSince(arrival)) < 10 * 60 }) { return }
            spots[i].arrivals.append(arrival)
            if spots[i].arrivals.count > Self.maxArrivals { spots[i].arrivals.removeFirst(spots[i].arrivals.count - Self.maxArrivals) }
        } else {
            spots.append(Spot(lat: coordinate.latitude, lng: coordinate.longitude, arrivals: [arrival]))
            index = spots.count - 1
            if spots.count > Self.maxSpots {
                // Am längsten nicht besuchte Orte zuerst vergessen
                spots.sort { ($0.arrivals.last ?? .distantPast) > ($1.arrivals.last ?? .distantPast) }
                spots.removeLast(spots.count - Self.maxSpots)
            }
        }
        Diag.log("Aufenthalt gemerkt: \(spots.firstIndex(where: { $0.coordinate.distance(to: coordinate) < Self.radius }).map { spots[$0].name ?? "Ort \($0 + 1)" } ?? "?") (\(Format.time.string(from: arrival)))")
        if index < spots.count, spots[index].name == nil { Task { await self.name(spotAt: coordinate) } }
        save()
    }

    /// Wahrscheinlichstes Ziel jetzt: Ankünfte der letzten 8 Wochen im Fenster „jetzt bis in 90 Minuten“,
    /// gleicher Wochentag zählt voll, gleiche Art Tag (Werktag/Wochenende) halb. Mindestens 3 solche Ankünfte.
    func likelyDestination(now: Date, from here: CLLocationCoordinate2D) -> Spot? {
        Self.likely(in: spots, now: now, from: here)
    }

    nonisolated static func likely(in spots: [Spot], now: Date, from here: CLLocationCoordinate2D) -> Spot? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        let weekend = calendar.isDateInWeekend(now)
        let nowMinutes = Self.minutes(now)
        var best: (spot: Spot, score: Double, count: Int)?
        for spot in spots where spot.coordinate.distance(to: here) > 500 {
            var score = 0.0, count = 0
            for arrival in spot.arrivals {
                let age = now.timeIntervalSince(arrival)
                guard age > 0, age < 56 * 86400 else { continue }
                var delta = Self.minutes(arrival) - nowMinutes
                if delta < -12 * 60 { delta += 24 * 60 }
                guard delta >= -15, delta <= 90 else { continue }
                let sameDay = calendar.component(.weekday, from: arrival) == weekday
                let sameKind = calendar.isDateInWeekend(arrival) == weekend
                guard sameDay || sameKind else { continue }
                score += (sameDay ? 1 : 0.5) * exp(-age / (30 * 86400))
                count += 1
            }
            if count >= 3, score >= 1.5, score > (best?.score ?? 0) { best = (spot, score, count) }
        }
        return best?.spot
    }

    func clear() {
        spots = []
        save()
        Diag.log("Gelernte Orte gelöscht")
    }

    // MARK: Intern

    nonisolated private static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Name: Favorit (Zuhause, Arbeit …) in der Nähe, sonst Ortsname oder Straße
    private func name(spotAt coordinate: CLLocationCoordinate2D) async {
        var name: String?
        let favorites = AppModel.shared.favorites
        let favs = [favorites.home, favorites.work].compactMap { $0 } + favorites.others
        if let fav = favs.first(where: { $0.coordinate.distance(to: coordinate) < Self.radius }) {
            name = fav.label
        } else if let p = try? await CLGeocoder().reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first {
            name = p.areasOfInterest?.first ?? [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
            if name?.isEmpty ?? true { name = p.locality }
        }
        guard let name, let i = spots.firstIndex(where: { $0.coordinate.distance(to: coordinate) < Self.radius }) else { return }
        spots[i].name = name
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(spots) else { return }
        // Im Hintergrund bei gesperrtem iPhone lesbar (CarPlay startet die App oft gesperrt)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
