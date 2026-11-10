import Foundation
import CoreLocation
import MapboxDirections

/// Höhenprofil und Wetter entlang einer Route für die Ladeplanung (wie ABRP): Steigungen kosten Energie,
/// Gefälle bringt über Rekuperation einen Teil zurück, Gegenwind und Kälte erhöhen den Verbrauch, Regen auch.
/// Quelle: Open-Meteo (Höhen aus Copernicus-DEM 90 m, Wettervorhersage stündlich) – frei, ohne Schlüssel.
struct RouteConditions: Sendable {
    struct Height: Sendable { let dist: Double; let meters: Double }
    struct Weather: Sendable {
        let dist: Double
        /// Unix-Zeit je Stunde
        let times: [Double]
        let temperature: [Double]
        /// m/s in 10 m Höhe
        let wind: [Double]
        /// Richtung, aus der der Wind kommt (Grad)
        let windFrom: [Double]
        /// mm/h
        let rain: [Double]
    }
    struct Sample: Sendable { let temperature: Double; let wind: Double; let windFrom: Double; let rain: Double }

    var heights: [Height] = []
    var weather: [Weather] = []
    var departure = Date()

    /// Höhe (m) an einer Stelle der Route, linear zwischen den Messpunkten
    func height(at d: Double) -> Double? {
        guard let first = heights.first, let last = heights.last else { return nil }
        if d <= first.dist { return first.meters }
        if d >= last.dist { return last.meters }
        var lo = 0, hi = heights.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if heights[mid].dist <= d { lo = mid } else { hi = mid } }
        let a = heights[lo], b = heights[hi]
        return a.meters + (b.meters - a.meters) * (d - a.dist) / max(b.dist - a.dist, 0.01)
    }

    /// Wetter am nächstgelegenen Messpunkt zu der Stunde, in der ich dort bin (Abfahrt + Fahrzeit bis dahin)
    func weather(at d: Double, after seconds: Double) -> Sample? {
        guard let w = weather.min(by: { abs($0.dist - d) < abs($1.dist - d) }), !w.times.isEmpty else { return nil }
        let t = departure.timeIntervalSince1970 + seconds
        let i = w.times.lastIndex { $0 <= t } ?? 0
        guard i < w.temperature.count, i < w.wind.count, i < w.windFrom.count, i < w.rain.count else { return nil }
        return Sample(temperature: w.temperature[i], wind: w.wind[i], windFrom: w.windFrom[i], rain: w.rain[i])
    }
}

/// Lädt und merkt sich die Bedingungen je Route. Höhen bleiben, Wetter gilt eine Stunde.
final class RouteConditionsService: @unchecked Sendable {
    static let shared = RouteConditionsService()

    private let lock = NSLock()
    private var cache: [String: (conditions: RouteConditions, at: Date)] = [:]
    private var loading = Set<String>()

    static func key(_ route: Route) -> String {
        let shape = route.shape?.coordinates
        let a = shape?.first, b = shape?.last
        return "\(Int(route.distance))-\(Int(route.expectedTravelTime))-\(a?.latitude ?? 0),\(a?.longitude ?? 0)-\(b?.latitude ?? 0),\(b?.longitude ?? 0)"
    }

    /// Sofort aus dem Speicher (für Stellen, die nicht warten können – CarPlay-Vorschau, Akku-Prognose)
    func cached(for route: Route) -> RouteConditions? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[Self.key(route)], Date().timeIntervalSince(hit.at) < 3600 else { return nil }
        return hit.conditions
    }

    /// Laden (oder aus dem Speicher). Ohne Netz: nil – die Planung rechnet dann ohne Höhe und Wetter.
    func conditions(for route: Route) async -> RouteConditions? {
        if let hit = cached(for: route) { return hit }
        let key = Self.key(route)
        let points = ChargePlanner.points(of: route)
        guard points.count > 1, let total = points.last?.dist, total > 0 else { return nil }
        async let heights = Self.heights(points: points, total: total)
        async let weather = Self.weather(points: points, total: total)
        let (h, w) = await (heights, weather)
        guard h != nil || w != nil else { return nil }
        let result = RouteConditions(heights: h ?? [], weather: w ?? [], departure: Date())
        lock.lock()
        if cache.count > 20 { cache.removeAll() }
        cache[key] = (result, Date())
        lock.unlock()
        Diag.log("Routenbedingungen: \(h?.count ?? 0) Höhenpunkte, \(w?.count ?? 0) Wetterpunkte für \(Int(total / 1000)) km")
        return result
    }

    /// Im Hintergrund vorladen (einmal je Route gleichzeitig)
    func prefetch(_ route: Route) {
        let key = Self.key(route)
        lock.lock()
        let skip = loading.contains(key) || cache[key].map { Date().timeIntervalSince($0.at) < 3600 } == true
        if !skip { loading.insert(key) }
        lock.unlock()
        guard !skip else { return }
        Task.detached(priority: .utility) {
            _ = await self.conditions(for: route)
            self.lock.lock(); self.loading.remove(key); self.lock.unlock()
        }
    }

    /// Punkte in festem Abstand entlang der Route
    static func sample(_ points: [ChargePlanner.RoutePoint], every spacing: Double) -> [ChargePlanner.RoutePoint] {
        var out: [ChargePlanner.RoutePoint] = []
        var next = 0.0
        for p in points where p.dist >= next {
            out.append(p); next = p.dist + spacing
        }
        if let last = points.last, out.last?.dist != last.dist { out.append(last) }
        return out
    }

    private static func coordinateQuery(_ ps: [ChargePlanner.RoutePoint]) -> String {
        let lat = ps.map { String(format: "%.4f", $0.coordinate.latitude) }.joined(separator: ",")
        let lng = ps.map { String(format: "%.4f", $0.coordinate.longitude) }.joined(separator: ",")
        return "latitude=\(lat)&longitude=\(lng)"
    }

    /// Höhen alle ~1 km (höchstens 1000 Punkte, je Anfrage 100)
    private static func heights(points: [ChargePlanner.RoutePoint], total: Double) async -> [RouteConditions.Height]? {
        let ps = sample(points, every: max(1_000, total / 1_000))
        let chunks = stride(from: 0, to: ps.count, by: 100).map { Array(ps[$0..<min($0 + 100, ps.count)]) }
        var result: [RouteConditions.Height] = []
        for chunk in chunks {
            struct Response: Decodable { let elevation: [Double] }
            guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?" + coordinateQuery(chunk)),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let r = try? JSONDecoder().decode(Response.self, from: data), r.elevation.count == chunk.count
            else { Diag.log("Höhenprofil nicht geladen"); return nil }
            result += zip(chunk, r.elevation).map { RouteConditions.Height(dist: $0.dist, meters: $1) }
        }
        return result
    }

    /// Wetter alle ~20 km (höchstens 50 Punkte, eine Anfrage), stündlich für die nächsten 2 Tage
    private static func weather(points: [ChargePlanner.RoutePoint], total: Double) async -> [RouteConditions.Weather]? {
        let ps = sample(points, every: max(20_000, total / 50))
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let wind_speed_10m: [Double?]
            let wind_direction_10m: [Double?]
            let precipitation: [Double?]
        }
        struct Location: Decodable { let hourly: Hourly }
        let query = coordinateQuery(ps) + "&hourly=temperature_2m,wind_speed_10m,wind_direction_10m,precipitation"
            + "&wind_speed_unit=ms&timeformat=unixtime&forecast_days=2&timezone=GMT"
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?" + query),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { Diag.log("Wetter entlang der Route nicht geladen"); return nil }
        // Ein Ort → Objekt, mehrere → Liste
        let locations = (try? JSONDecoder().decode([Location].self, from: data))
            ?? (try? JSONDecoder().decode(Location.self, from: data)).map { [$0] }
        guard let locations, locations.count == ps.count else { Diag.log("Wetter entlang der Route: unerwartete Antwort"); return nil }
        return zip(ps, locations).map { p, l in
            let h = l.hourly
            return RouteConditions.Weather(dist: p.dist, times: h.time,
                                           temperature: h.temperature_2m.map { $0 ?? 10 },
                                           wind: h.wind_speed_10m.map { $0 ?? 0 },
                                           windFrom: h.wind_direction_10m.map { $0 ?? 0 },
                                           rain: h.precipitation.map { $0 ?? 0 })
        }
    }
}
