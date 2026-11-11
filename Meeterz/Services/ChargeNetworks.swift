import Foundation

/// Bevorzugte und gemiedene Ladenetze (wie bei ABRP). Ein Netz = Betreiber, zusammengefasst über die erste
/// Namenshälfte („EnBW mobility+ AG“ und „EnBW“ → „enbw“). Nur auf dem Gerät gespeichert.
enum ChargeNetworks {
    enum Preference: String { case preferred, avoided }

    struct Network: Identifiable, Hashable {
        let id: String       // Schlüssel
        let name: String     // Anzeigename
        let sites: Int
    }

    /// Schlüssel eines Betreibers: erstes Wort (bei sehr kurzen Wörtern die ersten zwei), klein, ohne Satzzeichen
    static func key(_ operatorName: String) -> String {
        let words = operatorName.lowercased()
            .replacingOccurrences(of: "[^a-z0-9äöüéèčß. ]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        guard let first = words.first else { return "" }
        if first.count <= 2, !["bp", "ok"].contains(first), words.count > 1 { return first + " " + words[1] }
        return first
    }

    /// Die größten Netze in den gebündelten Daten (für die Auswahl)
    @MainActor static let all: [Network] = {
        var counts: [String: Int] = [:]
        var names: [String: [String: Int]] = [:]
        for s in ChargeSites.all where !s.operatorName.isEmpty {
            let k = key(s.operatorName)
            guard !k.isEmpty else { continue }
            counts[k, default: 0] += 1
            names[k, default: [:]][ChargeSite.short(s.operatorName), default: 0] += 1
        }
        return counts.filter { $0.value >= 20 }.map { k, n in
            // Kürzester häufiger Name: „EnBW“ statt „EnBW mobility+“
            let variants = names[k, default: [:]].filter { $0.value * 5 >= n }.keys
            let name = variants.min { $0.count < $1.count } ?? k
            return Network(id: k, name: name, sites: n)
        }.sorted { $0.sites > $1.sites }
    }()

    static var preferred: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ev.networks.preferred") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ev.networks.preferred") }
    }
    static var avoided: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ev.networks.avoided") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ev.networks.avoided") }
    }

    static func preference(_ key: String) -> Preference? {
        preferred.contains(key) ? .preferred : avoided.contains(key) ? .avoided : nil
    }

    static func set(_ key: String, _ p: Preference?) {
        var pre = preferred, avo = avoided
        pre.remove(key); avo.remove(key)
        if p == .preferred { pre.insert(key) }
        if p == .avoided { avo.insert(key) }
        preferred = pre; avoided = avo
        Diag.log("Ladenetz \(key): \(p?.rawValue ?? "egal")")
    }

    /// „2 bevorzugt · 1 gemieden“
    static var summary: String {
        let p = preferred.count, a = avoided.count
        if p == 0 && a == 0 { return String(localized: "Alle gleich") }
        return [p > 0 ? String(localized: "\(p) bevorzugt") : nil, a > 0 ? String(localized: "\(a) gemieden") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
