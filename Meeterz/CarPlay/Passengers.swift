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
    /// Alles, was auf meinen Karten nicht erscheint. Wer mit mir verabredet ist, bleibt bis zur Ankunft am
    /// Treffpunkt sichtbar – auch wenn ich ihn ausgeblendet habe (10.11.).
    var riding: Set<UUID> { ridingNow.union(hiddenForMe).subtracting(meetingPartners) }

    /// Treffen, bei denen der Freund schon angekommen ist (danach gilt wieder „ausgeblendet“)
    @ObservationIgnored private var arrivedAt: Set<String> = []

    /// Freunde mit angenommenem Treffen, die noch nicht am Treffpunkt sind
    var meetingPartners: Set<UUID> {
        let app = AppModel.shared
        var ids = Set<UUID>()
        for m in app.meetups.accepted {
            for partner in app.meetups.partners(of: m) where !arrivedAt.contains("\(m.id)-\(partner)") {
                if let p = app.hub.positions[partner], p.coordinate.distance(to: m.coordinate) < 100 {
                    arrivedAt.insert("\(m.id)-\(partner)")
                    continue
                }
                ids.insert(partner)
            }
        }
        return ids
    }

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
    @ObservationIgnored private var lastFix: [UUID: (coordinate: CLLocationCoordinate2D, ts: TimeInterval)] = [:]

    func reset() {
        ridingNow = []
        asked = []
        samples = [:]
        lastFix = [:]
    }

    /// Neue Freundesposition einordnen (bei jeder eigenen Meldung aufgerufen; je Zeitstempel nur einmal).
    /// Gibt den neuen Messpunkt zurück – nil, wenn die Position nicht neu ist oder meine Spur zu der Zeit fehlt.
    @discardableResult
    func observe(_ id: UUID, _ p: LivePosition) -> Sample? {
        var list = samples[id] ?? []
        guard list.last.map({ p.ts > $0.ts + 1 }) ?? true,
              let me = AppModel.shared.location.location(at: p.date) else { return nil }
        var same: Bool?
        // Richtung des Freundes: gemeldeter Kurs – fehlt er (Handy im Hintergrund meldet oft keinen), aus seiner
        // eigenen Spur. Ohne Richtung wurde Aufholen in gleicher Richtung als „an dir vorbeigefahren“ gemeldet (22.11.).
        var friendHeading = p.heading.flatMap { $0 >= 0 ? $0 : nil }
        if friendHeading == nil, let prev = lastFix[id], p.ts - prev.ts < 120, prev.coordinate.distance(to: p.coordinate) > 30 {
            friendHeading = prev.coordinate.bearing(to: p.coordinate)
        }
        lastFix[id] = (p.coordinate, p.ts)
        if let heading = friendHeading, me.course >= 0, me.speed > 2 {
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

    /// Fährt dicht mit mir: die letzten zeitgleichen Messpunkte (≥ 2) alle unter 150 m, mindestens einer davon in Fahrt.
    /// Ein Halt (Ampel, Stau) unterbricht die Reihe nicht mehr – vorher fing die Zählung nach jedem Stopp von vorn an,
    /// in der Stadt dauerte die Erkennung so oft 15 Minuten (19.11.).
    func isCompanion(_ id: UUID, minSamples: Int = 2, minSpan: TimeInterval = 0) -> Bool {
        guard let list = samples[id] else { return false }
        let close = list.reversed().prefix { $0.distance < 150 && $0.sameDirection != false }
        guard close.count >= minSamples, close.contains(where: \.moving),
              let newest = close.first, let oldest = close.last else { return false }
        return newest.ts - oldest.ts >= minSpan
    }

    enum Encounter { case pass, catchUp }

    /// Begegnung unterwegs: zeitgleich < 300 m, aber kein Mitfahrer. Wer von Anfang an dicht dabei ist, begegnet mir nicht.
    /// - `.pass`: Gegenverkehr/kreuzend. Bei unbekannter Richtung keine Meldung – lieber nichts als etwas Falsches (22.11.)
    /// - `.catchUp`: gleiche Richtung und vorher fahrend deutlich weiter weg – einer hat zum anderen aufgeholt.
    ///   Das war vorher ebenfalls „fährt an dir vorbei“, obwohl man danach zusammen weiterfährt (10.11.).
    func encounter(_ id: UUID) -> Encounter? {
        guard let list = samples[id], let now = list.last, now.distance < 300, now.moving,
              !isCompanion(id) else { return nil }
        guard let same = now.sameDirection else { return nil }
        if !same { return .pass }
        let wasFar = list.dropLast().contains { now.ts - $0.ts < 5 * 60 && $0.distance > 800 && $0.friendMoving }
        return wasFar ? .catchUp : nil
    }

    /// Alle 30 s aus CarPlay: wer fährt seit ≥ 1,5 Minuten zeitgleich dicht bei mir?
    /// Freundespositionen kommen verzögert – darum zählt der Abstand zu meiner Position zu ihrem Zeitstempel.
    func check(ask: (FriendRow) -> Bool) {
        let app = AppModel.shared
        var poke: [UUID] = []
        for item in app.friendsOnMapIncludingPassengers {
            let id = item.friend.friendId
            observe(id, item.position)
            guard !riding.contains(id), !asked.contains(id) else { continue }
            if isCompanion(id, minSamples: 2, minSpan: 60) {
                if ask(item.friend) { asked.insert(id) }   // nur als „gefragt“ merken, wenn die Frage auch erschien
            } else if let last = samples[id]?.last, last.distance < 300, item.position.age > 30,
                      Date().timeIntervalSince(pokedAt[id] ?? .distantPast) > 60 {
                // Nah dran, aber die Position ist alt: Ein Handy in der Tasche meldet sich im Hintergrund selten.
                // Frische Position anfordern (stiller Push), sonst fehlen die Messpunkte für die Erkennung.
                poke.append(id)
                pokedAt[id] = Date()
            }
        }
        if !poke.isEmpty { app.push.requestLocations(of: poke) }
    }
    @ObservationIgnored private var pokedAt: [UUID: Date] = [:]

    func setRiding(_ id: UUID, _ riding: Bool) {
        if riding { ridingNow.insert(id) } else { ridingNow.remove(id) }
        Diag.log("Mitfahrer \(riding ? "dabei" : "nicht mehr dabei"): \(AppModel.shared.friend(id)?.displayName ?? "?")")
    }
}

extension CarPlayController {
    /// „Wer fährt mit?“: Freunde von Hand als Mitfahrer markieren (Beifahrer, Rückbank) – zählen dann zum Konvoi.
    /// Nahe Freunde zuerst; die automatische Erkennung braucht ein paar Minuten gemeinsamer Fahrt.
    func showPassengerPicker() {
        let template = CPListTemplate(title: String(localized: "Wer fährt mit?"), sections: [])
        func render() {
            let app = AppModel.shared
            let me = app.location.lastLocation?.coordinate
            func distance(_ id: UUID) -> Double {
                guard let me, let p = app.hub.positions[id] ?? app.friend(id)?.lastKnown else { return .greatestFiniteMagnitude }
                return p.coordinate.distance(to: me)
            }
            let friends = app.friends.accepted.sorted { distance($0.friendId) < distance($1.friendId) }
            let items: [CPListItem] = friends.prefix(CPListTemplate.maximumItemCount).map { f in
                let riding = Passengers.shared.ridingNow.contains(f.friendId)
                let d = distance(f.friendId)
                let detail = riding ? String(localized: "fährt mit")
                    : d < 300 ? String(localized: "in der Nähe") : nil
                let item = CPListItem(text: f.firstName, detailText: detail,
                                      image: AvatarRenderer.image(initials: f.initials, color: FriendPalette.uiColor(for: f.friendId),
                                                                  faded: false, photo: app.avatars.image(for: f.friendId)),
                                      accessoryImage: riding ? UIImage(systemName: "checkmark.circle.fill") : nil, accessoryType: .none)
                item.handler = { [weak self] _, done in
                    MainActor.assumeIsolated {
                        Passengers.shared.setRiding(f.friendId, !riding)
                        self?.refreshFriendsAfterPassengerChange()
                        render()
                    }
                    done()
                }
                return item
            }
            template.updateSections([CPListSection(items: items, header: String(localized: "Gehört zum Konvoi, auch ohne eigenes Auto"),
                                                   sectionIndexTitle: nil)])
        }
        render()
        CarPlayUI.shared.push(template, animated: true)
    }

    /// „Fährt Annika bei dir mit?“ – Ja blendet sie für die Fahrt aus
    @discardableResult
    func askPassenger(_ friend: FriendRow) -> Bool {
        // Nicht während der Routenführung (Freunde sind dort ohnehin ausgeblendet) und erst 60 s nach ihrem Ende:
        // Die Erkennung läuft im Hintergrund weiter und wäre beim Beenden sofort fertig – die Frage käme dann
        // mitten in den Ansichtswechsel. Fährt die Person danach noch mit, kommt die Frage eine Minute später.
        // Auch während der Fahrt fragen (vorher nie – wer erst nach dem Losfahren erkannt wurde, blieb draußen).
        // Nur nicht in der ersten Minute nach dem Ende, da wechselt CarPlay gerade die Ansicht.
        guard Date().timeIntervalSince(navigationEndedAt) > 60 else { return false }
        guard let template = alertTemplate, template.currentNavigationAlert == nil else { return false }
        _ = template
        Diag.log("Mitfahrer-Frage: \(friend.displayName)")
        let first = friend.firstName
        let yes = CPAlertAction(title: String(localized: "Ja, fährt mit"), style: .default) { [weak self] _ in
            Task { @MainActor in
                Passengers.shared.setRiding(friend.friendId, true)
                self?.refreshFriendsAfterPassengerChange()
            }
        }
        let no = CPAlertAction(title: String(localized: "Nein"), style: .cancel) { _ in }
        let image = AvatarRenderer.image(initials: friend.initials, color: FriendPalette.uiColor(for: friend.friendId),
                                         faded: false, photo: AppModel.shared.avatars.image(for: friend.friendId))
        let alert = CPNavigationAlert(
            titleVariants: [String(localized: "Fährt \(first) bei dir mit?"), String(localized: "\(first) fährt mit?")],
            subtitleVariants: [String(localized: "Dann gehört \(first) zum Konvoi und verschwindet von der Karte")],
            image: image, primaryAction: yes, secondaryAction: no, duration: 20)
        return CarPlayUI.shared.alert(alert, priority: .low)
    }
}
