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
    /// Zeitgleicher Abstand je Freund: Freundesposition gegen meine Position *zu ihrem Zeitstempel*
    struct Sample {
        let ts: TimeInterval
        let distance: Double
        /// Gleiche Fahrtrichtung (nil = Richtung unbekannt)
        let sameDirection: Bool?
        let moving: Bool
        /// Freund selbst in Fahrt
        let friendMoving: Bool
    }
    @ObservationIgnored private var samples: [UUID: [Sample]] = [:]

    func reset() {
        ridingNow = []
        asked = []
        samples = [:]
    }

    /// Neue Freundesposition einordnen (bei jeder eigenen Meldung aufgerufen; je Zeitstempel nur einmal).
    /// Gibt den neuen Messpunkt zurück – nil, wenn die Position nicht neu ist oder meine Spur zu der Zeit fehlt.
    @discardableResult
    func observe(_ id: UUID, _ p: LivePosition) -> Sample? {
        var list = samples[id] ?? []
        guard list.last.map({ p.ts > $0.ts + 1 }) ?? true,
              let me = AppModel.shared.location.location(at: p.date) else { return nil }
        var same: Bool?
        if let heading = p.heading, heading >= 0, me.course >= 0, me.speed > 2 {
            let diff = abs((heading - me.course + 540).truncatingRemainder(dividingBy: 360) - 180)
            same = diff < 50
        }
        let sample = Sample(ts: p.ts, distance: p.coordinate.distance(to: me.coordinate), sameDirection: same, moving: me.speed > 4,
                            friendMoving: (p.speed ?? 0) > 3)
        list.append(sample)
        list.removeAll { p.ts - $0.ts > 10 * 60 }
        samples[id] = list
        return sample
    }

    /// Fährt dicht mit mir: die letzten zeitgleichen Messpunkte (≥ 2) alle unter 150 m, während ich fahre
    func isCompanion(_ id: UUID, minSamples: Int = 2, minSpan: TimeInterval = 0) -> Bool {
        guard let list = samples[id] else { return false }
        let close = list.reversed().prefix { $0.distance < 150 && $0.moving && $0.sameDirection != false }
        guard close.count >= minSamples, let newest = close.first, let oldest = close.last else { return false }
        return newest.ts - oldest.ts >= minSpan
    }

    /// „Fährt vorbei“: zeitgleich < 300 m, aber kein Mitfahrer – Gegenverkehr/kreuzend,
    /// oder vorher fahrend deutlich weiter weg (wirklich herangekommen – nicht: wartet und steigt zu). Wer von Anfang an dicht dabei ist, fährt nicht vorbei.
    func isPassing(_ id: UUID) -> Bool {
        guard let list = samples[id], let now = list.last, now.distance < 300, now.moving,
              !isCompanion(id) else { return false }
        if now.sameDirection == false { return true }
        return list.dropLast().contains { now.ts - $0.ts < 5 * 60 && $0.distance > 800 && $0.friendMoving }
    }

    /// Alle 30 s aus CarPlay: wer fährt seit ≥ 1,5 Minuten zeitgleich dicht bei mir?
    /// Freundespositionen kommen verzögert – darum zählt der Abstand zu meiner Position zu ihrem Zeitstempel.
    func check(ask: (FriendRow) -> Bool) {
        let app = AppModel.shared
        for item in app.friendsOnMapIncludingPassengers {
            let id = item.friend.friendId
            observe(id, item.position)
            guard !riding.contains(id), !asked.contains(id),
                  isCompanion(id, minSamples: 3, minSpan: 90) else { continue }
            if ask(item.friend) { asked.insert(id) }   // nur als „gefragt“ merken, wenn die Frage auch erschien
        }
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
        _ = template
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
        return CarPlayUI.shared.alert(alert)
    }
}
