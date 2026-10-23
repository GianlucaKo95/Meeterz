import Foundation
import UIKit
import CarPlay
import CoreLocation

/// Mitfahrer: Ein Freund, der dicht bei mir mitfährt, wird nach Rückfrage für diese Fahrt ausgeblendet
/// (bis CarPlay getrennt wird) – sonst klebt sein Bild am eigenen Pfeil und löst Konvoi-Hinweise aus.
@MainActor
final class Passengers {
    static let shared = Passengers()

    /// Für diese Fahrt ausgeblendete Freunde
    private(set) var riding: Set<UUID> = []
    /// Schon gefragt (Antwort „Nein“ oder offen) – nicht noch einmal
    private var asked: Set<UUID> = []
    /// Wie oft hintereinander (je 30 s) jemand dicht dabei war
    private var together: [UUID: Int] = [:]

    func reset() {
        riding = []
        asked = []
        together = [:]
    }

    /// Alle 30 s aus CarPlay: wer ist seit ≥ 1 Minute während der Fahrt höchstens 80 m entfernt?
    func check(ask: (FriendRow) -> Void) {
        let app = AppModel.shared
        guard let me = app.location.lastLocation, me.speed > 4 else { return }   // nur in Bewegung (> ~15 km/h)
        var seen: Set<UUID> = []
        for item in app.friendsOnMapIncludingPassengers {
            let id = item.friend.friendId
            guard !riding.contains(id), !asked.contains(id), item.position.age < 90 else { continue }
            let close = item.position.coordinate.distance(to: me.coordinate) < 80
            guard close else { continue }
            seen.insert(id)
            together[id, default: 0] += 1
            if together[id]! >= 2 {
                asked.insert(id)
                ask(item.friend)
            }
        }
        together = together.filter { seen.contains($0.key) }
    }

    func setRiding(_ id: UUID, _ riding: Bool) {
        if riding { self.riding.insert(id) } else { self.riding.remove(id) }
        Diag.log("Mitfahrer \(riding ? "ausgeblendet" : "eingeblendet"): \(AppModel.shared.friend(id)?.displayName ?? "?")")
    }
}

extension CarPlayController {
    /// „Fährt Annika bei dir mit?“ – Ja blendet sie für die Fahrt aus
    func askPassenger(_ friend: FriendRow) {
        guard let template = alertTemplate, template.currentNavigationAlert == nil else { return }
        let first = friend.displayName.split(separator: " ").first.map(String.init) ?? friend.displayName
        let yes = CPAlertAction(title: "Ja, ausblenden", style: .default) { [weak self] _ in
            Task { @MainActor in
                Passengers.shared.setRiding(friend.friendId, true)
                self?.refreshFriendsAfterPassengerChange()
            }
        }
        let no = CPAlertAction(title: "Nein", style: .cancel) { _ in }
        let image = AvatarRenderer.image(initials: friend.initials, color: FriendPalette.uiColor(for: friend.friendId),
                                         faded: false, photo: AppModel.shared.avatars.image(for: friend.friendId))
        let alert = CPNavigationAlert(
            titleVariants: ["Fährt \(first) bei dir mit?", "\(first) fährt mit?"],
            subtitleVariants: ["Dann blende ich \(first) für diese Fahrt aus"],
            image: image, primaryAction: yes, secondaryAction: no, duration: 20)
        template.present(navigationAlert: alert, animated: true)
    }
}
