import Foundation
import UIKit
import Supabase
import ActivityKit
import CoreLocation
import MapboxDirections
import MapboxNavigationCore

/// Startet, aktualisiert und beendet die Live-Aktivität der Navigation.
@MainActor
final class NavigationLiveActivityController {
    static let shared = NavigationLiveActivityController()

    private var activity: Activity<NavigationActivityAttributes>?
    private var lastState: NavigationActivityAttributes.ContentState?
    private var lastPush = Date.distantPast
    private var destination: CLLocationCoordinate2D?
    /// Token, mit dem unser Server die Live-Aktivität per Push starten darf (iOS erlaubt das Starten sonst nur mit der
    /// App im Vordergrund – CarPlay-Fahrten beginnen aber meist bei gesperrtem iPhone)
    private var pushToStartToken: String?
    private var watching = false
    private var waitingForPushStart = false

    /// Beim Start der App: Push-Token und per Push gestartete Aktivitäten beobachten
    func watch() {
        guard !watching else { return }
        watching = true
        Task { @MainActor in
            for await data in Activity<NavigationActivityAttributes>.pushToStartTokenUpdates {
                self.pushToStartToken = data.map { String(format: "%02x", $0) }.joined()
            }
        }
        Task { @MainActor in
            for await started in Activity<NavigationActivityAttributes>.activityUpdates {
                // Vom Server gestartet: übernehmen und ab jetzt selbst aktualisieren
                guard AppModel.shared.navigation.isNavigating else {
                    await started.end(nil, dismissalPolicy: .immediate); continue
                }
                if self.activity == nil || self.activity?.id == started.id {
                    self.activity = started
                    self.waitingForPushStart = false
                    Diag.log("Live-Aktivität per Push gestartet (Sperrbildschirm)")
                }
            }
        }
        // Reste einer früheren Fahrt (App beendet) aufräumen
        for old in Activity<NavigationActivityAttributes>.activities where !AppModel.shared.navigation.isNavigating {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(destinationName: String?, destination: CLLocationCoordinate2D?) {
        // Läuft schon eine für diese Fahrt (z. B. CarPlay getrennt), weiterverwenden
        if activity != nil, let destination, let old = self.destination, old.distance(to: destination) < 50 { return }
        end()
        // Wie Apple Karten: auch mit CarPlay auf dem Sperrbildschirm des iPhones
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Diag.log("Live-Aktivität: in den Einstellungen deaktiviert")
            return
        }
        self.destination = destination
        let state = NavigationActivityAttributes.ContentState(
            symbol: "arrow.up", instruction: String(localized: "Route wird gestartet"), distanceToTurn: 0,
            arrival: AppModel.shared.navigation.eta ?? Date().addingTimeInterval(AppModel.shared.navigation.remaining?.duration ?? 0),
            remainingDistance: AppModel.shared.navigation.remaining?.distance ?? 0,
            friendName: nil, friendInitials: nil, friendArrival: nil, friendHere: false)
        let attributes = NavigationActivityAttributes(destinationName: destinationName ?? String(localized: "Ziel"))
        lastState = state
        if UIApplication.shared.applicationState == .active {
            do {
                activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil),
                                                pushType: nil)
                return
            } catch {
                Diag.log("Live-Aktivität konnte nicht starten: \(error.localizedDescription)")
            }
        }
        startViaPush(attributes: attributes, state: state)
    }

    /// App im Hintergrund (CarPlay, iPhone gesperrt): unser Server startet die Aktivität per Push
    private func startViaPush(attributes: NavigationActivityAttributes, state: NavigationActivityAttributes.ContentState) {
        guard let token = pushToStartToken else {
            Diag.log("Live-Aktivität: App im Hintergrund und noch kein Push-Token – startet beim nächsten Öffnen")
            return
        }
        // Als fertiger JSON-Text: Datumswerte so, wie ActivityKit sie beim Entschlüsseln erwartet (Sekunden seit 2001,
        // Standard von JSONEncoder) – der Supabase-Client würde sie sonst als ISO-Text schicken
        guard let stateData = try? JSONEncoder().encode(state), let attributesData = try? JSONEncoder().encode(attributes),
              let stateText = String(data: stateData, encoding: .utf8),
              let attributesText = String(data: attributesData, encoding: .utf8) else { return }
        struct Body: Encodable {
            let token: String
            let env: String
            let attributes_type: String
            let attributes_json: String
            let content_state_json: String
            let title: String
            let body: String
        }
        let body = Body(token: token, env: AppConfig.pushEnvironment, attributes_type: "NavigationActivityAttributes",
                        attributes_json: attributesText, content_state_json: stateText, title: String(localized: "Navigation"),
                        body: attributes.destinationName)
        waitingForPushStart = true
        Task {
            do {
                try await Backend.client.functions.invoke("live_activity", options: FunctionInvokeOptions(body: body))
                Diag.log("Live-Aktivität: Start per Push angefragt")
            } catch {
                Diag.log("Live-Aktivität: Start per Push fehlgeschlagen (\(error.localizedDescription))")
            }
        }
    }

    /// App kommt nach vorn, Fahrt läuft, aber keine Aktivität (Push kam nicht an): jetzt direkt starten
    func ensureRunning() {
        let nav = AppModel.shared.navigation
        guard nav.isNavigating, activity == nil else { return }
        start(destinationName: nav.destination?.name, destination: nav.destination?.coordinate)
    }

    /// Aus dem Navigationsfortschritt. Gesendet wird bei neuer Abbiegung, deutlicher Änderung oder alle 15 s.
    func update(_ progress: RouteProgress) {
        guard let activity else { return }
        let step = progress.currentLegProgress.currentStepProgress
        let visual = step.currentVisualInstruction?.primaryInstruction
        let upcoming = progress.currentLegProgress.upcomingStep

        var state = NavigationActivityAttributes.ContentState(
            symbol: Self.symbol(type: visual?.maneuverType ?? upcoming?.maneuverType,
                                direction: visual?.maneuverDirection ?? upcoming?.maneuverDirection),
            instruction: visual?.text ?? upcoming?.instructions ?? "",
            distanceToTurn: step.distanceRemaining,
            arrival: Date().addingTimeInterval(progress.durationRemaining),
            remainingDistance: progress.distanceRemaining,
            friendName: nil, friendInitials: nil, friendArrival: nil, friendHere: false)
        addFriend(to: &state)

        let changedTurn = state.symbol != lastState?.symbol || state.instruction != lastState?.instruction
        let distanceJump = abs(state.distanceToTurn - (lastState?.distanceToTurn ?? 0)) > max(50, state.distanceToTurn * 0.2)
        let friendChanged = state.friendHere != lastState?.friendHere || state.friendName != lastState?.friendName
        guard changedTurn || distanceJump || friendChanged || Date().timeIntervalSince(lastPush) > 15 else { return }

        lastState = state
        lastPush = Date()
        Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))) }
    }

    func end() {
        waitingForPushStart = false
        // Auch per Push gestartete, die wir (noch) nicht kennen
        for other in Activity<NavigationActivityAttributes>.activities where other.id != activity?.id {
            Task { await other.end(nil, dismissalPolicy: .immediate) }
        }
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        destination = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Freund, der zum selben Ziel unterwegs ist (oder schon dort steht)
    private func addFriend(to state: inout NavigationActivityAttributes.ContentState) {
        guard let destination else { return }
        let app = AppModel.shared
        for friend in app.friends.accepted {
            let firstName = friend.displayName.split(separator: " ").first.map(String.init) ?? friend.displayName
            if let pos = app.friendsOnMap.first(where: { $0.friend.friendId == friend.friendId })?.position,
               pos.coordinate.distance(to: destination) < 100, pos.age < 10 * 60 {
                state.friendName = firstName
                state.friendInitials = friend.initials
                state.friendHere = true
                return
            }
            if let route = app.routes.friendRoutes[friend.friendId],
               route.destination.distance(to: destination) < 300, route.eta > Date() {
                state.friendName = firstName
                state.friendInitials = friend.initials
                state.friendArrival = route.eta
                return
            }
        }
    }

    static func symbol(type: ManeuverType?, direction: ManeuverDirection?) -> String {
        switch type {
        case .arrive?: return "flag.checkered"
        case .takeRoundabout?, .takeRotary?, .turnAtRoundabout?, .exitRoundabout?, .exitRotary?:
            return "arrow.triangle.turn.up.right.circle"
        default: break
        }
        switch direction {
        case .sharpLeft?, .left?: return "arrow.turn.up.left"
        case .slightLeft?: return "arrow.up.left"
        case .sharpRight?, .right?: return "arrow.turn.up.right"
        case .slightRight?: return "arrow.up.right"
        case .uTurn?: return "arrow.uturn.left"
        default: return "arrow.up"
        }
    }
}
