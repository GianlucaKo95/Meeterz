import Foundation
import CoreLocation
import MapKit

/// Mapbox Search Box API (Ziele und Orte in der Nähe eines Treffpunkts).
enum SearchService {
    enum Category: String, CaseIterable, Identifiable {
        case restArea, coffee, restaurant, gasStation, park

        var id: String { rawValue }

        /// Raststätten und Tankstellen sind nur mit dem Auto erreichbar und als Treffpunkt sinnvoll

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

    /// Ortssuche: Apple-Orte und Mapbox gleichzeitig, zusammengeführt und nach Passung und Nähe sortiert.
    /// Nur Mapbox lieferte ab und an völlig falsche Treffer (unscharfe Suche, 22.11.); Apple kennt Geschäfte in
    /// Deutschland meist besser, Mapbox ergänzt Adressen und was Apple nicht hat.
    static func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [Place] {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "10")]
        if let near { items.append(proximity(near)) }
        async let apple = appleSearch(query, near: near)
        let mapbox: [Place]
        do { mapbox = try await request(path: "forward", items: items) }
        catch { let a = await apple; if a.isEmpty { throw error }; mapbox = [] }
        return SearchRanking.merge(apple: await apple, mapbox: mapbox, query: query, near: near)
    }

    private static func appleSearch(_ query: String, near: CLLocationCoordinate2D?) async -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let near { request.region = MKCoordinateRegion(center: near, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.prefix(10).compactMap { item in
            guard let name = item.name, !name.isEmpty else { return nil }
            let address: String?
            if #available(iOS 26.0, *) { address = item.address?.fullAddress } else { address = item.placemark.title }
            return Place(id: "apple:" + String(format: "%.5f,%.5f", item.coordinate.latitude, item.coordinate.longitude),
                         name: name, address: address?.replacingOccurrences(of: "\n", with: ", "), coordinate: item.coordinate,
                         symbol: item.pointOfInterestCategory == nil ? "mappin.circle.fill" : symbol(type: "poi", maki: nil, categories: [item.pointOfInterestCategory!.rawValue.lowercased()]))
        }
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

    /// Firmen-/Lagername statt Tankstelle (Händler, Spedition …)
    static func looksLikeCompany(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["gesellschaft", "vertrieb", "lager", "handel", "spedition", "logistik", "service gmbh", "mineralöl", "heizöl"]
            .contains { n.contains($0) }
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

    /// Details eines Karten-POI (Ortskarte, wenn Apple den Ort nicht kennt; wie Android PlaceSearch.Details)
    struct Details: Equatable {
        var category: String?, address: String?, phone: String?, website: URL?
        var rating: Double?, reviews: Int?
        /// Öffnungszeiten je Tag (0 = Montag … 6 = Sonntag) als Minuten-Spannen; nil = unbekannt
        var hours: [[Range<Int>]]?
        /// OSM-Öffnungszeiten, die sich nicht in Spannen übersetzen ließen – dann als Text zeigen
        var hoursText: String? = nil
        /// Angaben (auch) aus OpenStreetMap – Hinweis „© OpenStreetMap“ zeigen
        var osm = false

        static func weekday(_ date: Date = .now) -> Int { (Calendar.current.component(.weekday, from: date) + 5) % 7 }

        /// true/false = jetzt geöffnet/geschlossen, nil = unbekannt
        func openNow(_ date: Date = .now) -> Bool? {
            guard let h = hours else { return nil }
            let day = Self.weekday(date)
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let min = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            // Spannen über Mitternacht sind am Folgetag als > 1440 eingetragen
            return h[day].contains { $0.contains(min) } || h[(day + 6) % 7].contains { $0.contains(min + 1440) }
        }
    }

    /// Details zum angetippten POI: Mapbox, und was dort fehlt (Website, Telefon, Öffnungszeiten), aus OpenStreetMap.
    /// Mapbox hat in Deutschland zu vielen kleineren Orten nur Name und Adresse (18.11., z. B. Restaurant in Duisburg).
    static func details(name: String, at c: CLLocationCoordinate2D) async -> Details? {
        async let mapbox = mapboxDetails(name: name, at: c)
        async let osm = OsmPlaces.info(name: name, at: c)
        let m = await mapbox
        guard let o = await osm else { return m }
        let osmHours = o.openingHours.flatMap(OsmPlaces.parse)
        let base = m ?? Details(category: nil, address: nil, phone: nil, website: nil, rating: nil, reviews: nil, hours: nil)
        var merged = base
        merged.phone = base.phone ?? o.phone
        merged.website = base.website ?? o.website.flatMap { URL(string: $0.hasPrefix("http") ? $0 : "https://\($0)") }
        merged.hours = base.hours ?? osmHours
        merged.hoursText = base.hours == nil && osmHours == nil ? o.openingHours : nil
        merged.osm = merged != base
        return merged
    }

    /// Mapbox-Treffer zum angetippten POI: gleicher Name in der Nähe (≤ 150 m). Ein Forward-Request, keine Session.
    private static func mapboxDetails(name: String, at c: CLLocationCoordinate2D) async -> Details? {
        var comps = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/forward")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: name), URLQueryItem(name: "types", value: "poi"), URLQueryItem(name: "limit", value: "5"),
            proximity(c), URLQueryItem(name: "language", value: Bundle.main.preferredLocalizations.first ?? "en"),
            URLQueryItem(name: "access_token", value: AppConfig.mapboxToken),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: comps.url!),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return nil }
        let near = features.compactMap { $0["properties"] as? [String: Any] }.compactMap { p -> ([String: Any], Double)? in
            guard let co = p["coordinates"] as? [String: Any], let lat = co["latitude"] as? Double, let lng = co["longitude"] as? Double else { return nil }
            let d = CLLocationCoordinate2D(latitude: lat, longitude: lng).distance(to: c)
            return d < 150 ? (p, d) : nil
        }.min { $0.1 < $1.1 }?.0
        guard let p = near else { return nil }
        let meta = p["metadata"] as? [String: Any]
        let periods = (meta?["open_hours"] as? [String: Any])?["periods"] as? [[String: Any]]
        if let periods { Diag.log("POI-Öffnungszeiten \(name): \(periods)") }
        let hours: [[Range<Int>]]? = periods.map { list in
            var days = Array(repeating: [Range<Int>](), count: 7)
            func minutes(_ s: String) -> Int { (Int(s.prefix(2)) ?? 0) * 60 + (Int(s.dropFirst(2)) ?? 0) }
            for e in list {
                guard let o = e["open"] as? [String: Any], let od = o["day"] as? Int, let ot = o["time"] as? String else { continue }
                let start = minutes(ot)
                // ohne „close“ = rund um die Uhr
                var end = 1440
                if let cl = e["close"] as? [String: Any], let cd = cl["day"] as? Int, let ct = cl["time"] as? String {
                    end = ((cd - od + 7) % 7) * 1440 + minutes(ct)
                }
                // Mapbox zählt ab Sonntag (0 = So): Boda Borg „So 10–20, Mo 14–20“, Büros „Mo–Fr, Fr bis 13 Uhr“ (Log 20./21.11.)
                days[(od + 6) % 7].append(start..<max(end, start + 1))
            }
            return days
        }
        let website = (meta?["website"] as? String).flatMap { URL(string: $0.hasPrefix("http") ? $0 : "https://\($0)") }
        return Details(
            category: (p["poi_category"] as? [String])?.first.map { $0.prefix(1).uppercased() + $0.dropFirst() },
            address: (p["full_address"] ?? p["address"]) as? String,
            phone: (meta?["phone"] as? String).flatMap { $0.isEmpty ? nil : $0 }, website: website,
            rating: meta?["rating"] as? Double, reviews: meta?["review_count"] as? Int, hours: hours)
    }

    private static func proximity(_ c: CLLocationCoordinate2D) -> URLQueryItem {
        URLQueryItem(name: "proximity", value: "\(c.longitude),\(c.latitude)")
    }

    private static func request(path: String, items: [URLQueryItem]) async throws -> [Place] {
        var comps = URLComponents(string: "https://api.mapbox.com/search/searchbox/v1/\(path)")!
        comps.queryItems = items + [
            // Ergebnisse in der Sprache der App (vorher fest Deutsch: „Rom, Italien“ auch in der italienischen App)
            URLQueryItem(name: "language", value: Bundle.main.preferredLocalizations.first ?? "en"),
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

/// Fahrzeiten unter den Kacheln der Zielsuche (wie Apple „Arbeit · 40 Min.“): EINE Mapbox-Matrix-Anfrage von hier zu
/// bis zu 9 Zielen (driving-traffic erlaubt 10 Koordinaten). Neu gerechnet erst nach 500 m Weg oder 5 Minuten –
/// abgerechnet wird je Ziel, das Freikontingent liegt bei 100.000 im Monat.
@MainActor
enum TileTravelTimes {
    private static var origin: CLLocation?
    private static var at = Date.distantPast
    private static var times: [String: TimeInterval] = [:]

    static func key(_ c: CLLocationCoordinate2D) -> String { String(format: "%.4f,%.4f", c.latitude, c.longitude) }

    /// Fahrzeiten (s) je Ziel-Schlüssel; fehlende Ziele bleiben weg (dann zeigt die Kachel die Entfernung)
    static func get(from here: CLLocation, to targets: [CLLocationCoordinate2D]) async -> [String: TimeInterval] {
        let wanted = Array(targets.filter { $0.distance(to: here.coordinate) >= 200 }.prefix(9))
        let fresh = origin.map { $0.distance(from: here) < 500 } == true && Date().timeIntervalSince(at) < 5 * 60
        if fresh, wanted.allSatisfy({ times[key($0)] != nil }) { return times }
        guard !wanted.isEmpty else { return times }
        let coords = ([here.coordinate] + wanted).map { String(format: "%.6f,%.6f", $0.longitude, $0.latitude) }.joined(separator: ";")
        var url = URLComponents(string: "https://api.mapbox.com/directions-matrix/v1/mapbox/driving-traffic/\(coords)")!
        url.queryItems = [
            URLQueryItem(name: "sources", value: "0"),
            URLQueryItem(name: "annotations", value: "duration"),
            URLQueryItem(name: "access_token", value: AppConfig.mapboxToken),
        ]
        struct Response: Decodable { let durations: [[Double?]]? }
        guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
              let row = (try? JSONDecoder().decode(Response.self, from: data))?.durations?.first else { return times }
        var result: [String: TimeInterval] = [:]
        for (i, c) in wanted.enumerated() where i + 1 < row.count {
            if let d = row[i + 1] { result[key(c)] = d }
        }
        origin = here; at = Date(); times = result
        return result
    }
}

/// Treffer zusammenführen und sortieren (eigene Datei-freie Logik, getestet in SearchRankingTests)
enum SearchRanking {
    /// Wie gut passt der Treffer zur Eingabe? 0 = gar nicht (kein Wort der Eingabe kommt in Name/Adresse vor)
    static func match(_ place: Place, query: String) -> Double {
        let fold: (String) -> String = { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        let name = fold(place.name), all = name + " " + fold(place.address ?? "")
        let q = fold(query).trimmingCharacters(in: .whitespaces)
        let words = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0 }
        if name == q { return 3 }
        if name.hasPrefix(q) { return 2.5 }
        if name.contains(q) { return 2 }
        // Wortanfänge zählen (auch Tippfehler am Ende: „Boda Bor“)
        let tokens = all.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let hits = words.filter { w in tokens.contains { $0.hasPrefix(w) } }.count
        return hits == 0 ? 0 : Double(hits) / Double(words.count) * 1.5
    }

    static func merge(apple: [Place], mapbox: [Place], query: String, near: CLLocationCoordinate2D?) -> [Place] {
        var out: [Place] = []
        for p in apple + mapbox {
            // Gleicher Ort aus beiden Quellen: den ersten (Apple) behalten
            if out.contains(where: { $0.coordinate.distance(to: p.coordinate) < 150 && match($0, query: p.name) >= 2 }) { continue }
            out.append(p)
        }
        func score(_ p: Place) -> Double {
            let m = match(p, query: query)
            guard let near else { return m }
            let km = p.coordinate.distance(to: near) / 1000
            return m - log10(1 + km) * 0.6   // 10 km kosten 0,6, 100 km 1,2, 1000 km 1,8
        }
        let ranked = out.map { ($0, match($0, query: query), score($0)) }
        // Passt mindestens ein Treffer, fallen die ohne jede Übereinstimmung weg („völlig falsche“ Treffer)
        let anyMatch = ranked.contains { $0.1 > 0 }
        return ranked.filter { !anyMatch || $0.1 > 0 }.sorted { $0.2 > $1.2 }.prefix(10).map(\.0)
    }
}
