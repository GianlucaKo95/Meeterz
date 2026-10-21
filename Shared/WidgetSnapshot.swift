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

    /// "TEAMID.de.koeven.meeterz.shared" – ohne Signatur (Simulator-Build) leer, dann ohne Gruppe
    private static var accessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "MeeterzKeychainPrefix") as? String,
              !prefix.isEmpty, !prefix.contains("$(") else { return nil }
        return prefix + "de.koeven.meeterz.shared"
    }

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

    static func clear() {
        SecItemDelete(query() as CFDictionary)
    }
}
