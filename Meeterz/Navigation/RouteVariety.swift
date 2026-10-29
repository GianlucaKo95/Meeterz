import Foundation
import CoreLocation
@_spi(MapboxInternal) import MapboxNavigationCore
import MapboxDirections
import MapboxNavigationNative

/// Bis zu drei Routen zur Wahl, nach festen Kriterien statt „was Mapbox gerade als Alternative liefert“:
/// 1. Schnellste (Mapbox' Hauptroute), 2. Kürzeste, 3. Ohne Autobahn.
///
/// Mapbox kennt kein „kürzeste Route“ und liefert oft nur eine Alternative. Darum eine zweite Anfrage ohne Autobahnen;
/// aus allen Kandidaten werden die drei gewählt und zu einer Routenauswahl zusammengeführt (Hauptroute + Alternativen),
/// sodass iPhone und CarPlay sie wie gewohnt anzeigen und starten. Klappt etwas nicht, bleibt es bei Mapbox' Routen.
enum RouteVariety {
    enum Kind { case fastest, shortest, noMotorway, other }

    /// Routen erweitern (nur Auto, ohne Zwischenstopps)
    static func widen(_ routes: NavigationRoutes, options: NavigationRouteOptions,
                      using provider: RoutingProvider) async -> NavigationRoutes {
        guard options.waypoints.count == 2, !options.roadClassesToAvoid.contains(.motorway),
              usesMotorway(routes.mainRoute.route),
              // Lange Strecken (Berlin–Kopenhagen): ohne Autobahn ergibt das keinen Sinn – gar nicht erst anfragen
              routes.mainRoute.route.distance <= maxDistanceForNoMotorway else {
            Diag.log("Routenauswahl: keine Zusatzroute angefragt (Autobahn auf der schnellsten: \(usesMotorway(routes.mainRoute.route)), \(Int(routes.mainRoute.route.distance / 1000)) km)")
            return routes
        }
        let plain = NavigationRouteOptions(waypoints: options.waypoints, profileIdentifier: options.profileIdentifier,
                                           locale: options.locale, distanceUnit: .kilometer)
        plain.roadClassesToAvoid = options.roadClassesToAvoid.union(.motorway)
        let extra: Route
        do { extra = try await provider.calculateRoutes(options: plain).value.mainRoute.route } catch {
            Diag.log("Routenauswahl: Route ohne Autobahn nicht berechnet (\(error.localizedDescription))")
            return routes
        }

        let fastest = routes.mainRoute.route
        // Kandidaten mit Kennung (Route ist ein Wert, kein Objekt): -1 = Zusatzroute ohne Autobahn
        var candidates: [(id: Int, route: Route)] = routes.alternativeRoutes.enumerated().map { ($0.offset, $0.element.route) }
        candidates.append((-1, extra))
        candidates.removeAll { same($0.route, fastest) }
        // Nur Routen, die zeitlich noch eine echte Wahl sind (höchstens 25 % bzw. 15 Min. länger als die schnellste)
        candidates.removeAll { !reasonable($0.route, comparedTo: fastest) }
        var unique: [(id: Int, route: Route)] = []
        for c in candidates where !unique.contains(where: { same($0.route, c.route) }) { unique.append(c) }

        var picked: [(id: Int, route: Route)] = []
        if let shortest = unique.min(by: { $0.route.distance < $1.route.distance }), shortest.route.distance < fastest.distance * 0.97 {
            picked.append(shortest)
        }
        if !picked.contains(where: { $0.id == -1 }), let e = unique.first(where: { $0.id == -1 }) { picked.append(e) }
        for c in unique.sorted(by: { $0.route.expectedTravelTime < $1.route.expectedTravelTime }) where picked.count < 2 {
            if !picked.contains(where: { $0.id == c.id }) { picked.append(c) }
        }
        // Ohne die Zusatzroute ist nichts gewonnen – Mapbox' Auswahl bleibt
        guard picked.contains(where: { $0.id == -1 }) else {
            let mins = Int((extra.expectedTravelTime - fastest.expectedTravelTime) / 60)
            Diag.log("Routenauswahl: Route ohne Autobahn nicht angeboten (\(mins >= 0 ? "+" : "")\(mins) Min., \(Int(extra.distance / 1000)) km – gleich oder zu langsam)")
            return routes
        }

        let all = [fastest] + picked.map(\.route)
        do {
            let response = RouteResponse(httpResponse: nil, identifier: nil, routes: all, waypoints: routes.waypoints,
                                         options: .route(options),
                                         credentials: Credentials(accessToken: AppConfig.mapboxToken, host: nil))
            let merged = try await NavigationRoutes(routeResponse: response, routeIndex: 0, responseOrigin: .online)
            let labels = (1..<all.count).map { label(for: $0, in: all) }
            Diag.log("Routenauswahl: \(merged.alternativeRoutes.count + 1) Routen (Schnellste, \(labels.joined(separator: ", ")))")
            return merged
        } catch {
            Diag.log("Routenauswahl: Zusatzroute nicht übernommen (\(error.localizedDescription))")
            return routes
        }
    }

    /// Bis zu dieser Länge der schnellsten Route wird „Ohne Autobahn“ angeboten
    static let maxDistanceForNoMotorway: CLLocationDistance = 150_000

    /// Noch eine sinnvolle Wahl: höchstens 25 % länger unterwegs, mindestens aber 15 Min. Spielraum
    static func reasonable(_ route: Route, comparedTo fastest: Route) -> Bool {
        route.expectedTravelTime <= max(fastest.expectedTravelTime * 1.25, fastest.expectedTravelTime + 15 * 60)
    }

    /// Art einer Route innerhalb der Auswahl (erste = schnellste)
    static func kind(at index: Int, among all: [Route]) -> Kind {
        guard index > 0, let first = all.first, all.indices.contains(index) else { return .fastest }
        let route = all[index]
        let rest = all.indices.dropFirst()
        if let shortest = rest.min(by: { all[$0].distance < all[$1].distance }), shortest == index,
           route.distance < first.distance * 0.97 { return .shortest }
        if usesMotorway(first), !usesMotorway(route) { return .noMotorway }
        return .other
    }

    /// „Schnellste“, „Kürzeste“, „Ohne Autobahn“, sonst „Alternative n“
    static func label(for index: Int, in all: [Route]) -> String {
        guard all.indices.contains(index) else { return String(localized: "Alternative \(index)") }
        let k = kind(at: index, among: all)
        return k == .other ? String(localized: "Alternative \(index)") : label(k)
    }

    static func label(_ kind: Kind) -> String {
        switch kind {
        case .fastest: String(localized: "Schnellste")
        case .shortest: String(localized: "Kürzeste")
        case .noMotorway: String(localized: "Ohne Autobahn")
        case .other: String(localized: "Alternative")
        }
    }

    static func usesMotorway(_ route: Route) -> Bool {
        route.legs.contains { leg in
            leg.steps.contains { step in
                (step.intersections ?? []).contains { $0.outletRoadClasses?.contains(.motorway) == true }
            }
        }
    }

    /// Praktisch dieselbe Strecke (Länge und Fahrzeit je höchstens 2 % auseinander)
    static func same(_ a: Route, _ b: Route) -> Bool {
        abs(a.distance - b.distance) <= max(a.distance, b.distance) * 0.02
            && abs(a.expectedTravelTime - b.expectedTravelTime) <= max(a.expectedTravelTime, b.expectedTravelTime) * 0.02
    }
}
