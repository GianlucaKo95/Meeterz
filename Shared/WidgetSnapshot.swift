import Foundation
import Security

/// Datenstand für die Widgets. Die App schreibt ihn in einen gemeinsamen Schlüsselbund-Eintrag,
/// die Widget-Erweiterung liest ihn (keine eigene Anmeldung, kein Netz im Widget).
struct WidgetSnapshot: Codable {
    struct Friend: Codable, Hashable {
        var name: String
        var initials: String
        /// Meter von mir (zum Zeitpunkt des Schreibens), nil = unbekannt
        var distance: Double?
        /// „unterwegs nach …“ bzw. nil
        var heading: String?
        var arrival: Date?
        /// Zeitpunkt der letzten Position des Freundes
        var seen: Date
    }

    struct Meetup: Codable, Hashable {
        var place: String
        var with: String
        var friendArrival: Date?
        var myArrival: Date?
    }

    var updated: Date
    var sharing: Bool
    var sharingUntil: Date?
    var incognito: Bool
    var friends: [Friend]
    var meetup: Meetup?

    static let empty = WidgetSnapshot(updated: .distantPast, sharing: false, sharingUntil: nil,
                                      incognito: false, friends: [], meetup: nil)
}

enum WidgetSnapshotStore {
    private static let service = "de.koeven.meeterz.widget"
    private static let account = "snapshot"

    /// Gemeinsame Schlüsselbund-Gruppe von App und Widget: "TEAMID.de.koeven.meeterz.shared".
    ///
    /// Früher kam die Team-ID aus der Info.plist ($(AppIdentifierPrefix)). War die beim Bauen nicht eingesetzt,
    /// schrieb jede Seite in ihre eigene Standard-Gruppe – App und Widget sahen sich nie.
    /// Jetzt wird die Team-ID zur Laufzeit aus dem Schlüsselbund selbst gelesen. Ohne Signatur (Simulator) nil.
    static let accessGroup: String? = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "de.koeven.meeterz.teamprobe",
            kSecAttrAccount as String: "probe",
        ]
        var lookup = probe
        lookup[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        var status = SecItemCopyMatching(lookup as CFDictionary, &out)
        if status == errSecItemNotFound {
            var add = probe
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecReturnAttributes as String] = true
            status = SecItemAdd(add as CFDictionary, &out)
        }
        guard status == errSecSuccess,
              let attrs = out as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let team = group.split(separator: ".").first, team.count == 10
        else { return nil }
        return "\(team).de.koeven.meeterz.shared"
    }()

    /// Für das Diagnoseprotokoll
    static var groupDescription: String { accessGroup ?? "keine (ohne Signatur)" }

    private static func query() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let update: [String: Any] = [
            kSecValueData as String: data,
            // Widgets laufen auch bei gesperrtem Gerät (nach dem ersten Entsperren)
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query().merging(update) { $1 } as CFDictionary, nil)
        }
    }

    static func load() -> WidgetSnapshot? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    // MARK: Protokoll der Widget-Erweiterung (erscheint im Diagnoseprotokoll der App)

    private static func logQuery() -> [String: Any] {
        var q = query()
        q[kSecAttrAccount as String] = "log"
        return q
    }

    static func appendLog(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "dd.MM. HH:mm:ss"
        var lines = readLog()
        lines.append("\(f.string(from: Date())) Widget: \(line)")
        if lines.count > 30 { lines.removeFirst(lines.count - 30) }
        guard let data = try? JSONEncoder().encode(lines) else { return }
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(logQuery() as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            SecItemAdd(logQuery().merging(update) { $1 } as CFDictionary, nil)
        }
    }

    static func readLog() -> [String] {
        var q = logQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Ergebnis des Lesens (für die Diagnose): „ok“, „leer“ oder der Schlüsselbund-Fehler (-25308 = Gerät gesperrt)
    static func loadStatus() -> String {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: return "ok"
        case errSecItemNotFound: return "leer"
        default: return "Fehler \(status)"
        }
    }

    static func clear() {
        SecItemDelete(query() as CFDictionary)
    }
}
