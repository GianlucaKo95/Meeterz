import Foundation
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

    func start(destinationName: String?, destination: CLLocationCoordinate2D?) {
        end()
        // Im Auto zeigt CarPlay die Abbiegung schon selbst im Dashboard – die Live-Aktivität erschiene dort doppelt.
        // Sie startet erst, wenn CarPlay getrennt wird und die Fahrt weiterläuft (siehe CarPlayController.disconnect).
        guard !CarPlayController.shared.isConnected else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Diag.log("Live-Aktivität: in den Einstellungen deaktiviert")
            return
        }
        self.destination = destination
        let state = NavigationActivityAttributes.ContentState(
            symbol: "arrow.up", instruction: "Route wird gestartet", distanceToTurn: 0,
            arrival: AppModel.shared.navigation.eta ?? Date().addingTimeInterval(AppModel.shared.navigation.remaining?.duration ?? 0),
            remainingDistance: AppModel.shared.navigation.remaining?.distance ?? 0,
            friendName: nil, friendInitials: nil, friendArrival: nil, friendHere: false)
        do {
            activity = try Activity.request(
                attributes: NavigationActivityAttributes(destinationName: destinationName ?? "Ziel"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            lastState = state
        } catch {
            Diag.log("Live-Aktivität konnte nicht starten: \(error.localizedDescription)")
        }
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

    private static func symbol(type: ManeuverType?, direction: ManeuverDirection?) -> String {
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
