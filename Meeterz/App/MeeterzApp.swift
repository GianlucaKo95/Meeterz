import SwiftUI
import Supabase

enum AppConfig {
    static func value(_ key: String) -> String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty else {
            fatalError("\(key) fehlt – Config.xcconfig prüfen")
        }
        return v
    }
}

enum Backend {
    static let client = SupabaseClient(
        supabaseURL: URL(string: AppConfig.value("SUPABASE_URL"))!,
        supabaseKey: AppConfig.value("SUPABASE_ANON_KEY")
    )
}

@main
struct MeeterzApp: App {
    @State private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .task { await auth.start() }
        }
    }
}
