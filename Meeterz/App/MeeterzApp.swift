import SwiftUI
import Supabase
import UserNotifications

enum AppConfig {
    static func value(_ key: String) -> String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty else {
            fatalError("\(key) fehlt – Config.xcconfig prüfen")
        }
        return v
    }

    static var mapboxToken: String { value("MBXAccessToken") }
    static var pushEnvironment: String {
        (Bundle.main.object(forInfoDictionaryKey: "MEETERZ_PUSH_ENV") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "development"
    }
}

enum Backend {
    /// Postgres liefert Zeitstempel mit Mikrosekunden („…33.308854+00:00“); das Standard-Dekodieren
    /// verträgt das nicht überall – deshalb eine tolerante Variante.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Datum nicht lesbar: \(raw)"))
        }
        return d
    }()

    static func parseDate(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        // Nachkommastellen auf 3 Ziffern kürzen
        let trimmed = raw.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: trimmed) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }

    static let client = SupabaseClient(
        supabaseURL: URL(string: AppConfig.value("SUPABASE_URL"))!,
        supabaseKey: AppConfig.value("SUPABASE_ANON_KEY"),
        options: SupabaseClientOptions(db: .init(decoder: decoder))
    )
}

@main
struct MeeterzApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
                .environment(AppModel.shared.auth)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await AppModel.shared.auth.start() }
        }
    }
}

/// Nur für Push: Geräte-Token an Supabase melden, Benachrichtigungen im Vordergrund zeigen.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await AppModel.shared.push.store(token: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Ohne bezahlten Account (Personal Team) gibt es kein Push – kein Fehler für den Nutzer.
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Task { @MainActor in await AppModel.shared.refreshSocial() }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await AppModel.shared.refreshSocial()
    }
}
