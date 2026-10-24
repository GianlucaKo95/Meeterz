import Foundation
import UIKit
import CarPlay
import CoreLocation
import Observation

/// Mitfahrer: Ein Freund, der dicht bei mir mitfährt, wird nach Rückfrage für diese Fahrt ausgeblendet
/// (bis CarPlay getrennt wird) – sonst klebt sein Bild am eigenen Pfeil und löst Konvoi-Hinweise aus.
@MainActor @Observable
final class Passengers {
    static let shared = Passengers()

    /// Für diese Fahrt ausgeblendete Freunde (Mitfahrer)
    private(set) var ridingNow: Set<UUID> = []
    /// Auf meiner Karte ausgeblendet, bis ich sie wieder einblende. Nur für mich: Teilen läuft in beide Richtungen weiter.
    private(set) var hiddenForMe: Set<UUID> = Set((UserDefaults.standard.array(forKey: "map.hiddenFriends") as? [String] ?? []).compactMap(UUID.init))
    /// Alles, was auf meinen Karten nicht erscheint
    var riding: Set<UUID> { ridingNow.union(hiddenForMe) }

    func isHiddenForMe(_ id: UUID) -> Bool { hiddenForMe.contains(id) }

    func setHiddenForMe(_ id: UUID, _ hidden: Bool) {
        if hidden { hiddenForMe.insert(id) } else { hiddenForMe.remove(id); ridingNow.remove(id) }
        UserDefaults.standard.set(hiddenForMe.map(\.uuidString), forKey: "map.hiddenFriends")
        Diag.log("Auf meiner Karte \(hidden ? "ausgeblendet" : "eingeblendet"): \(AppModel.shared.friend(id)?.displayName ?? "?")")
    }
    @ObservationIgnored
    /// Schon gefragt (Antwort „Nein“ oder offen) – nicht noch einmal
    private var asked: Set<UUID> = []
    @ObservationIgnored
    /// Wie oft hintereinander (je 30 s) jemand dicht dabei war
    private var together: [UUID: Int] = [:]

    func reset() {
        ridingNow = []
        asked = []
        together = [:]
    }

    /// Alle 30 s aus CarPlay: wer fährt seit ≥ 1,5 Minuten dicht bei mir in dieselbe Richtung?
    /// (Vorher genügte „in der Nähe“ – ein Freund, der vorbeifuhr oder dessen Position veraltet war, löste die Frage aus.)
    func check(ask: (FriendRow) -> Bool) {
        let app = AppModel.shared
        guard let me = app.location.lastLocation, me.speed > 4, me.course >= 0 else { return }   // nur in Fahrt (> ~15 km/h)
        var seen: Set<UUID> = []
        for item in app.friendsOnMapIncludingPassengers {
            let id = item.friend.friendId
            let p = item.position
            guard !self.riding.contains(id), !asked.contains(id), p.age < 45 else { continue }   // nur frische Positionen
            guard p.coordinate.distance(to: me.coordinate) < 80, (p.speed ?? 0) > 4 else { continue }   // nah und selbst in Fahrt
            if let heading = p.heading, heading >= 0 {
                let diff = abs((heading - me.course + 540).truncatingRemainder(dividingBy: 360) - 180)
                guard diff < 45 else { continue }   // gleiche Richtung
            }
            seen.insert(id)
            together[id, default: 0] += 1
            if together[id]! >= 3, ask(item.friend) {   // nur als „gefragt“ merken, wenn die Frage auch erschien
                asked.insert(id)
            }
        }
        together = together.filter { seen.contains($0.key) }
    }

    func setRiding(_ id: UUID, _ riding: Bool) {
        if riding { ridingNow.insert(id) } else { ridingNow.remove(id) }
        Diag.log("Mitfahrer \(riding ? "ausgeblendet" : "eingeblendet"): \(AppModel.shared.friend(id)?.displayName ?? "?")")
    }
}

extension CarPlayController {
    /// „Fährt Annika bei dir mit?“ – Ja blendet sie für die Fahrt aus
    @discardableResult
    func askPassenger(_ friend: FriendRow) -> Bool {
        guard let template = alertTemplate, template.currentNavigationAlert == nil else { return false }
        Diag.log("Mitfahrer-Frage: \(friend.displayName)")
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
        return true
    }
}
