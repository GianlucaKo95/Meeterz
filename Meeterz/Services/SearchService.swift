import Foundation
import CoreLocation

/// Mapbox Search Box API (Ziele und Orte in der Nähe eines Treffpunkts).
enum SearchService {
    enum Category: String, CaseIterable, Identifiable {
        case restArea, coffee, restaurant, gasStation, park

        var id: String { rawValue }

        /// Raststätten und Tankstellen sind nur mit dem Auto erreichbar und als Treffpunkt sinnvoll
        var carOnly: Bool { self == .restArea || self == .gasStation }

        /// Welche Orte passen zu den Fortbewegungsarten beider? Ist einer zu Fuß oder mit dem Rad unterwegs,
        /// entfallen Raststätte und Tankstelle; dann gibt es zusätzlich Parks.
        static func available(me: TravelMode, friend: TravelMode) -> [Category] {
            TravelMode.canMeetOnRoute(me, friend)
                ? [.restArea, .coffee, .restaurant, .gasStation]
                : [.coffee, .restaurant, .park]
        }

        var title: String {
            switch self {
            case .restArea: String(localized: "Raststätte")
            case .coffee: String(localized: "Café")
            case .restaurant: String(localized: "Essen")
            case .gasStation: String(localized: "Tanken")
            case .park: String(localized: "Park")
            }
        }
    }

    enum SearchError: LocalizedError {
        case quotaExceeded, failed
        var errorDescription: String? {
            switch self {
            case .quotaExceeded: String(localized: "Das Suchkontingent ist für diesen Monat aufgebraucht.")
            case .failed: String(localized: "Die Suche ist gerade nicht erreichbar.")
            }
        }
    }

    private struct Response: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable { let coordinates: [Double] }
            struct Properties: Decodable {
                let mapbox_id: String?
                let name: String?
                let full_address: String?
                let place_formatted: String?
                let feature_type: String?
                let maki: String?
                let poi_category: [String]?
            }
            let geometry: Geometry
            let properties: Properties
        }
        let features: [Feature]
    }

    static func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [Place] {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "10")]
        if let near { items.append(proximity(near)) }
        return try await request(path: "forward", items: items)
    }

    static func places(_ category: Category, near: CLLocationCoordinate2D, limit: Int = 6) async throws -> [Place] {
        var items = [proximity(near), URLQueryItem(name: "limit", value: String(limit))]
        switch category {
        case .restArea:
            items.append(URLQueryItem(name: "q", value: "Raststätte"))
            return try await request(path: "forward", items: items)
                .filter { $0.coordinate.distance(to: near) < 8_000 }
        case .coffee:
            return try await request(path: "category/coffee", items: items)
        case .restaurant:
            return try await request(path: "category/restaurant", items: items)
        case .gasStation:
            return try await request(path: "category/gas_station", items: items)
        case .park:
            return try await request(path: "category/park", items: items)
        }
    }

    /// Kategorien für unterwegs (CarPlay): Tanken, Laden, Parken, Essen, Café
    enum Stopover: String, CaseIterable, Identifiable {
        case gas, charging, parking, food, coffee
        var id: String { rawValue }

        var title: String {
            switch self {
            case .gas: String(localized: "Tanken")
            case .charging: String(localized: "Laden")
            case .parking: String(localized: "Parken")
            case .food: String(localized: "Essen")
            case .coffee: String(localized: "Café")
            }
        }

        var symbol: String {
            switch self {
            case .gas: "fuelpump.fill"
            case .charging: "bolt.car.fill"
            case .parking: "parkingsign.circle.fill"
            case .food: "fork.knife"
            case .coffee: "cup.and.saucer.fill"
            }
        }

        /// Kategorie-ID der Mapbox Search Box API
        fileprivate var canonical: String {
            switch self {
            case .gas: "gas_station"
            case .charging: "charging_station"
            case .parking: "parking_lot"
            case .food: "restaurant"
            case .coffee: "coffee"
            }
        }

        /// Freitextsuche, falls die Kategorie nichts liefert
        fileprivate var fallbackQuery: String {
            switch self {
            case .gas: String(localized: "Tankstelle")
            case .charging: String(localized: "Ladestation")
            case .parking: String(localized: "Parkplatz")
            case .food: String(localized: "Restaurant")
            case .coffee: String(localized: "Café")
            }
        }
    }

    /// Orte einer Kategorie. Mit `route` sucht Mapbox entlang der Strecke (höchstens `detourMinutes` Umweg),
    /// sonst um `near` herum. Liefert die Kategorie nichts, folgt eine Freitextsuche in der Nähe.
    static func stopovers(_ kind: Stopover, near: CLLocationCoordinate2D, route: [CLLocationCoordinate2D]?,
                          detourMinutes: Int = 5, limit: Int = 10) async throws -> [Place] {
        var items = [proximity(near), URLQueryItem(name: "limit", value: String(limit))]
        if let route, route.count > 1 {
            items += [
                URLQueryItem(name: "sar_type", value: "isochrone"),
                URLQueryItem(name: "route", value: Polyline.encode(route)),
                URLQueryItem(name: "route_geometry", value: "polyline"),
                URLQueryItem(name: "time_deviation", value: String(detourMinutes)),
            ]
        }
        do {
            let found = try await request(path: "category/\(kind.canonical)", items: items)
            if !found.isEmpty { return found }
        } catch SearchError.quotaExceeded {
            throw SearchError.quotaExceeded
        } catch {
            // unbekannte Kategorie o. Ä. → Freitextsuche
        }
        return try await search(kind.fallbackQuery, near: near)
    }

    /// Passendes Symbol zur Ortsart (Mapbox „maki“-Symbole bzw. Kategorien)
    static func symbol(type: String?, maki: String?, categories: [String]) -> String {
        let key = ([maki ?? ""] + categories).joined(separator: " ").lowercased()
        func has(_ words: String...) -> Bool { words.contains { key.contains($0) } }
        switch type {
        case "address", "street", "block": return "house.fill"
        case "place", "locality", "neighborhood", "district", "region", "postcode", "country": return "building.2.fill"
        default: break
        }
        if has("rail", "train", "bahnhof") { return "tram.fill" }
        if has("bus") { return "bus.fill" }
        if has("airport", "airfield") { return "airplane" }
        if has("charging") { return "bolt.car.fill" }
        if has("fuel", "gas_station", "tankstelle") { return "fuelpump.fill" }
        if has("parking") { return "parkingsign.circle.fill" }
        if has("cafe", "coffee") { return "cup.and.saucer.fill" }
        if has("restaurant", "food", "fast-food", "bar", "beer") { return "fork.knife" }
        if has("grocery", "supermarket", "shop", "store") { return "cart.fill" }
        if has("lodging", "hotel") { return "bed.double.fill" }
        if has("hospital", "doctor", "pharmacy") { return "cross.case.fill" }
        if has("park", "garden") { return "tree.fill" }
        if has("school", "college", "university") { return "graduationcap.fill" }
        if has("museum", "monument", "attraction") { return "building.columns.fill" }
        if has("fitness", "stadium", "pitch") { return "figure.run" }
        return "mappin.circle.fill"
    }

    private static func proximity(_ c: CLLocationCoordinate2D) -> URLQueryItem {
        URLQueryItem(name: "proximity", value: "\(c.longitude),\(c.latitude)")
    }

    private static func request(path: String, items: [URLQueryItem]) async throws -> [Place] {
        var comps = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/\(path)")!
        comps.queryItems = items + [
            URLQueryItem(name: "language", value: "de"),
            URLQueryItem(name: "access_token", value: AppConfig.mapboxToken),
        ]
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: comps.url!))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 402 || status == 429 { throw SearchError.quotaExceeded }
        guard status == 200 else { throw SearchError.failed }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.features.compactMap { f in
            guard f.geometry.coordinates.count >= 2, let name = f.properties.name else { return nil }
            return Place(
                id: f.properties.mapbox_id ?? UUID().uuidString,
                name: name,
                address: f.properties.full_address ?? f.properties.place_formatted,
                coordinate: .init(latitude: f.geometry.coordinates[1], longitude: f.geometry.coordinates[0]),
                symbol: symbol(type: f.properties.feature_type, maki: f.properties.maki,
                               categories: f.properties.poi_category ?? [])
            )
        }
    }
}

/// Google-Polyline (Genauigkeit 5) für die Routensuche
enum Polyline {
    static func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        var out = ""
        var lastLat = 0, lastLng = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded())
            let lng = Int((c.longitude * 1e5).rounded())
            out += value(lat - lastLat) + value(lng - lastLng)
            lastLat = lat; lastLng = lng
        }
        return out
    }

    private static func value(_ v: Int) -> String {
        var n = v < 0 ? ~(v << 1) : (v << 1)
        var s = ""
        while n >= 0x20 {
            s.append(Character(UnicodeScalar(UInt8((0x20 | (n & 0x1f)) + 63))))
            n >>= 5
        }
        s.append(Character(UnicodeScalar(UInt8(n + 63))))
        return s
    }
}
