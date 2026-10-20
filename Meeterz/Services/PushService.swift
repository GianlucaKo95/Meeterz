import Foundation
import UIKit
import UserNotifications
import Supabase

/// Push-Registrierung und Benachrichtigung anderer Nutzer über die Edge Function `notify`.
/// Ohne bezahlten Developer Account schlägt die Registrierung still fehl – die App funktioniert trotzdem.
@MainActor
final class PushService {
    enum Kind: String, Encodable {
        case friendRequest = "friend_request"
        case friendAccepted = "friend_accepted"
        case meetupProposed = "meetup_proposed"
        case meetupAccepted = "meetup_accepted"
        case meetupDeclined = "meetup_declined"
    }

    private var client: SupabaseClient { Backend.client }

    func registerIfPossible() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func store(token: String) async {
        struct Params: Encodable { let device_token: String; let env: String }
        _ = try? await client.rpc("register_device",
                                  params: Params(device_token: token, env: AppConfig.pushEnvironment)).execute()
    }

    /// Bittet Freunde, kurz ihren Standort zu senden (stiller Push). Fehler sind egal – es klappt beim nächsten Mal.
    func requestLocations(of users: [UUID]) {
        struct Body: Encodable { let targets: [UUID] }
        Task {
            try? await client.functions.invoke("request_location", options: FunctionInvokeOptions(body: Body(targets: users)))
        }
    }

    /// Feuert und vergisst – eine fehlende Push-Konfiguration darf nie den eigentlichen Vorgang stören.
    func notify(_ kind: Kind, to user: UUID, meetupId: UUID? = nil) {
        struct Body: Encodable { let kind: Kind; let target: UUID; let meetup_id: UUID? }
        let body = Body(kind: kind, target: user, meetup_id: meetupId)
        Task {
            try? await client.functions.invoke("notify", options: FunctionInvokeOptions(body: body))
        }
    }
}
