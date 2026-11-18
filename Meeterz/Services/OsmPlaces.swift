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
