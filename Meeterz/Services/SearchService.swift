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
            case .restArea: "Raststätte"
            case .coffee: "Café"
            case .restaurant: "Essen"
            case .gasStation: "Tanken"
            case .park: "Park"
            }
        }
    }

    enum SearchError: LocalizedError {
        case quotaExceeded, failed
        var errorDescription: String? {
            switch self {
            case .quotaExceeded: "Das Suchkontingent ist für diesen Monat aufgebraucht."
            case .failed: "Die Suche ist gerade nicht erreichbar."
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
                coordinate: .init(latitude: f.geometry.coordinates[1], longitude: f.geometry.coordinates[0])
            )
        }
    }
}
