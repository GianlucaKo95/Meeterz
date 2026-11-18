import Foundation
import CoreLocation

/// Ortsangaben aus OpenStreetMap (Overpass API, ODbL – Hinweis „© OpenStreetMap“): Website, Telefon, Öffnungszeiten
/// für POIs, zu denen Mapbox nichts hat (wie OsmPlaces.kt). Ein Request je Tipp, gleicher Name im Umkreis von 80 m.
enum OsmPlaces {
    struct Info { let website: String?; let phone: String?; let openingHours: String? }

    static func info(name: String, at c: CLLocationCoordinate2D) async -> Info? {
        // Regex-Sonderzeichen und Anführungszeichen weglassen – der Name wird als Teilstring gesucht
        let clean = name.replacingOccurrences(of: #"[\\^$.|?*+()\[\]{}"]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        let query = #"[out:json][timeout:8];nwr(around:80,\#(c.latitude),\#(c.longitude))["name"~"\#(clean)",i];out tags 5;"#
        var comps = URLComponents(string: "https://overpass-api.de/api/interpreter")!
        comps.queryItems = [URLQueryItem(name: "data", value: query)]
        var request = URLRequest(url: comps.url!)
        request.setValue("Meeterz/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return nil }
        func value(_ t: [String: String], _ keys: String...) -> String? { keys.lazy.compactMap { t[$0] }.first { !$0.isEmpty } }
        let tags = elements.compactMap { $0["tags"] as? [String: String] }
        guard let t = tags.first(where: { value($0, "website", "contact:website", "phone", "contact:phone", "opening_hours") != nil })
        else { return nil }
        return Info(website: value(t, "website", "contact:website", "url"), phone: value(t, "phone", "contact:phone"),
                    openingHours: value(t, "opening_hours"))
    }

    /// Öffnungszeiten für mehrere Orte mit EINER Abfrage (Listen in CarPlay): je Ort derselbe Name im Umkreis von 80 m.
    /// Gibt die Orte zurück, wo bekannt mit `hours`.
    static func withHours(_ places: [Place]) async -> [Place] {
        func clean(_ n: String) -> String {
            n.replacingOccurrences(of: #"[\\^$.|?*+()\[\]{}"]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        let parts = places.filter { !clean($0.name).isEmpty }.map {
            #"nwr(around:80,\#($0.coordinate.latitude),\#($0.coordinate.longitude))["name"~"\#(clean($0.name))",i]["opening_hours"];"#
        }
        guard !parts.isEmpty else { return places }
        var comps = URLComponents(string: "https://overpass-api.de/api/interpreter")!
        comps.queryItems = [URLQueryItem(name: "data", value: "[out:json][timeout:8];(\(parts.joined()));out tags center;")]
        var request = URLRequest(url: comps.url!, timeoutInterval: 4)
        request.setValue("Meeterz/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return places }
        return places.map { place in
            let hit = elements.first { e in
                let c = (e["center"] as? [String: Any]) ?? e
                guard let lat = c["lat"] as? Double, let lng = c["lon"] as? Double,
                      let name = (e["tags"] as? [String: String])?["name"] else { return false }
                return CLLocationCoordinate2D(latitude: lat, longitude: lng).distance(to: place.coordinate) < 150
                    && (name.localizedCaseInsensitiveContains(place.name) || place.name.localizedCaseInsensitiveContains(name))
            }
            guard let text = (hit?["tags"] as? [String: String])?["opening_hours"], let hours = parse(text) else { return place }
            var copy = place
            copy.hours = hours
            return copy
        }
    }

    /// „Geöffnet bis 23:00“, „Geschlossen · öffnet 17:00“, „Geschlossen“ bzw. „24 Stunden geöffnet“ – für Listen im Auto
    static func status(_ hours: [[Range<Int>]], now: Date = .now) -> String {
        let day = SearchService.Details.weekday(now)
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let min = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }
        if hours[day].contains(where: { $0.lowerBound == 0 && $0.upperBound >= 1440 }) { return String(localized: "24 Stunden geöffnet") }
        // offen seit gestern (über Mitternacht) oder jetzt
        if let r = hours[(day + 6) % 7].first(where: { $0.contains(min + 1440) }) { return String(localized: "Geöffnet bis \(hhmm(r.upperBound))") }
        if let r = hours[day].first(where: { $0.contains(min) }) { return String(localized: "Geöffnet bis \(hhmm(r.upperBound))") }
        if let r = hours[day].filter({ $0.lowerBound > min }).min(by: { $0.lowerBound < $1.lowerBound }) {
            return String(localized: "Geschlossen · öffnet \(hhmm(r.lowerBound))")
        }
        return String(localized: "Geschlossen")
    }

    private static let dayNames = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    /// OSM-`opening_hours` in Minuten-Spannen je Tag (0 = Montag) wie SearchService.Details.hours. Versteht den üblichen
    /// Teil („Mo-Fr 09:00-18:00; Sa 10:00-14:00; Su off“, „24/7“, mehrere Zeiten, über Mitternacht); Feiertagsregeln
    /// („PH off“) werden übersprungen. Alles andere (Monate, Wochen, Kommentare) → nil, dann wird der Text gezeigt.
    static func parse(_ text: String) -> [[Range<Int>]]? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s == "24/7" { return Array(repeating: [0..<1440], count: 7) }
        var days = Array(repeating: [Range<Int>](), count: 7)
        var any = false
        for raw in s.split(separator: ";").map(String.init) {
            // Feiertage/Schulferien aus der Tagesliste nehmen; eine reine Feiertagsregel fällt damit weg
            let holiday = raw.range(of: #"\b(PH|SH)\b"#, options: .regularExpression) != nil
            let rule = raw.replacingOccurrences(of: #"\s*,?\s*\b(PH|SH)\b\s*,?"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let startsWithDay = dayNames.contains { rule.hasPrefix($0) }
            if rule.isEmpty || (holiday && !startsWithDay) { continue }
            // Tagesliste vorne, Zeiten dahinter
            var daySpec = "", rest = rule
            if startsWithDay {
                let parts = rule.split(separator: " ", maxSplits: 1).map(String.init)
                daySpec = parts[0]; rest = parts.count > 1 ? parts[1] : ""
            }
            var set: [Int] = []
            if daySpec.isEmpty { set = Array(0..<7) } else {
                for part in daySpec.split(separator: ",") {
                    let ends = part.split(separator: "-").map(String.init)
                    guard let from = dayNames.firstIndex(of: ends[0]),
                          let to = dayNames.firstIndex(of: ends.count > 1 ? ends[1] : ends[0]) else { return nil }
                    set += (0...((to - from + 7) % 7)).map { (from + $0) % 7 }
                }
            }
            rest = rest.trimmingCharacters(in: .whitespaces)
            var spans: [Range<Int>] = []
            if rest != "off" && rest != "closed" {
                for t in rest.split(separator: ",") {
                    let p = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
                    let nums = p.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { Int($0) }
                    guard nums.count == 4, p.range(of: #"^\d{1,2}:\d{2}-\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
                    else { return nil }
                    let start = nums[0] * 60 + nums[1]
                    var end = nums[2] * 60 + nums[3]
                    if end <= start { end += 1440 }   // über Mitternacht
                    spans.append(start..<end)
                }
            }
            for d in set { days[d] = spans }
            any = true
        }
        return any ? days : nil
    }
}
