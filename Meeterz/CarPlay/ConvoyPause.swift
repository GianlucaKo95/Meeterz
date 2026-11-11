import Foundation
import UIKit
import CarPlay
import CoreLocation
import Observation

/// Konvoi-Pause: Jemand tippt „Pause vorschlagen“, Meeterz wählt selbst einen Halt, den alle im Konvoi noch vor sich
/// haben – mit Ladesäule, sobald einer ein E-Auto fährt. Alle anderen bekommen den Vorschlag mit „Dabei“ / „Nein“;
/// wer zusagt, bekommt den Halt als Zwischenstopp.
///
/// Übertragen wird über die vorhandenen Standort-Kanäle („loc:<id>“, Ereignisse „pause“ und „pause_reply“) – kein
/// eigener Server-Teil. Feldnamen nur gemeinsam mit Android ändern (ConvoyPause.kt).
@MainActor @Observable
final class ConvoyPause {
    static let shared = ConvoyPause()

    struct Proposal: Codable, Identifiable, Equatable {
        let id: UUID
        let from: UUID
        let fromName: String
        let name: String
        let lat: Double
        let lng: Double
        /// Halt mit Schnelllader (weil ein E-Auto dabei ist)
        let charger: Bool
        let kw: Double?
        let members: [UUID]
        let ts: TimeInterval
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    }

    struct Reply: Codable {
        let id: UUID
        let userId: UUID
        let accept: Bool
    }

    /// Offener Vorschlag fürs iPhone (ohne CarPlay)
    var prompt: Proposal?

    @ObservationIgnored private var handled = Set<UUID>()
    @ObservationIgnored private var mine: Proposal?
    @ObservationIgnored private var proposing = false

    private var app: AppModel { AppModel.shared }

    // MARK: Vorschlagen

    func propose() async {
        guard !proposing else { return }
        proposing = true
        defer { proposing = false }
        let members = ConvoyTracker.shared.members()
        guard app.navigation.isNavigating, let me = app.profile, !members.isEmpty else {
            notice(String(localized: "Gerade fährt niemand mit dir im Konvoi."))
            return
        }
        guard let route = ConvoyTracker.shared.routeProfile() else {
            notice(String(localized: "Keine Route für die Pause gefunden."))
            return
        }
        // Erreichbar für alle: hinter dem, der am weitesten vorn ist, mit 3 km Luft zum Abfahren
        let lead = max(0, members.compactMap(\.gap).max() ?? 0)
        let total = route.cumulative.last ?? 0
        let start = route.mine + lead + 3_000
        let end = min(total - 2_000, start + 80_000)
        guard end > start else {
            notice(String(localized: "Bis zum Ziel ist kein Platz mehr für eine Pause."))
            return
        }
        let ev = (EVSettings.enabled && EVSettings.vehicle != nil)
            || members.contains { app.hub.positions[$0.friend.friendId]?.ev == true }
        Diag.log("Konvoi-Pause: suche \(ev ? "Ladesäule" : "Rastplatz") zwischen \(Int(start / 1000)) und \(Int(end / 1000)) km (Vorsprung \(Int(lead)) m)")

        let pick: (name: String, coordinate: CLLocationCoordinate2D, kw: Double?)?
        if ev { pick = chargeStop(route: route, start: start, end: end) }
        else { pick = await restStop(route: route, start: start, end: end) }
        guard let pick else {
            notice(ev ? String(localized: "Keine Ladesäule auf der Strecke gefunden, die alle noch erreichen.")
                      : String(localized: "Kein Rastplatz auf der Strecke gefunden, den alle noch erreichen."))
            return
        }
        let proposal = Proposal(id: UUID(), from: me.id, fromName: me.displayName, name: pick.name,
                                lat: pick.coordinate.latitude, lng: pick.coordinate.longitude, charger: ev, kw: pick.kw,
                                members: members.map(\.friend.friendId), ts: Date().timeIntervalSince1970)
        mine = proposal
        handled.insert(proposal.id)
        await app.hub.broadcast(event: "pause", proposal)
        Diag.log("Konvoi-Pause vorgeschlagen: \(pick.name) an \(members.count) Mitfahrende")
        await app.navigation.addStop(place(proposal))
        notice(String(localized: "Pause vorgeschlagen: \(pick.name)"))
    }

    /// Schnelllader (≥ 50 kW, bevorzugt ≥ 100 kW) höchstens 800 m neben der Strecke – der erste, den alle erreichen
    private func chargeStop(route: (coords: [CLLocationCoordinate2D], cumulative: [Double], mine: Double),
                            start: Double, end: Double) -> (String, CLLocationCoordinate2D, Double?)? {
        let segment = zip(route.coords, route.cumulative).filter { $0.1 >= start && $0.1 <= end }.map(\.0)
        guard !segment.isEmpty else { return nil }
        let lats = segment.map(\.latitude), lngs = segment.map(\.longitude)
        let box = (lats.min()! - 0.01, lats.max()! + 0.01, lngs.min()! - 0.015, lngs.max()! + 0.015)
        var found: [(site: ChargeSite, along: Double)] = []
        for site in ChargeSites.all where site.plannedKW >= 50 {
            let c = site.coordinate
            guard c.latitude >= box.0, c.latitude <= box.1, c.longitude >= box.2, c.longitude <= box.3,
                  let along = ConvoyTracker.shared.along(c, within: 800), along >= start, along <= end else { continue }
            found.append((site, along))
        }
        let best = found.filter { $0.site.maxKW >= 100 }.min { $0.along < $1.along } ?? found.min { $0.along < $1.along }
        return best.map { ($0.site.title, $0.site.coordinate, $0.site.powerKnown ? $0.site.maxKW : nil) }
    }

    /// Raststätte (sonst Tankstelle) höchstens 800 m neben der Strecke – die erste, die alle erreichen
    private func restStop(route: (coords: [CLLocationCoordinate2D], cumulative: [Double], mine: Double),
                          start: Double, end: Double) async -> (String, CLLocationCoordinate2D, Double?)? {
        func point(at meters: Double) -> CLLocationCoordinate2D? {
            guard let i = route.cumulative.firstIndex(where: { $0 >= meters }) else { return nil }
            return route.coords[i]
        }
        var found: [(place: Place, along: Double)] = []
        for offset in [8_000.0, 25_000, 50_000] where start + offset - 8_000 < end {
            guard let near = point(at: min(start + offset, end)) else { continue }
            let places = (try? await SearchService.search(String(localized: "Raststätte"), near: near)) ?? []
            for p in places {
                if let along = ConvoyTracker.shared.along(p.coordinate, within: 800), along >= start, along <= end { found.append((p, along)) }
            }
            if !found.isEmpty { break }
        }
        if found.isEmpty {
            // Ohne Raststätte: Tankstelle direkt an der Strecke (Toilette, Kaffee)
            let segment = zip(route.coords, route.cumulative).filter { $0.1 >= start && $0.1 <= end }.map(\.0)
            if let near = segment.first, segment.count > 1 {
                let places = (try? await SearchService.stopovers(.gas, near: near, route: Array(segment.prefix(400)))) ?? []
                for p in places {
                    if let along = ConvoyTracker.shared.along(p.coordinate, within: 800), along >= start, along <= end { found.append((p, along)) }
                }
            }
        }
        return found.min { $0.along < $1.along }.map { ($0.place.name, $0.place.coordinate, nil) }
    }

    // MARK: Empfangen

    func received(_ p: Proposal) {
        guard let me = app.profile?.id, p.members.contains(me), !handled.contains(p.id),
              Date().timeIntervalSince1970 - p.ts < 15 * 60 else { return }
        handled.insert(p.id)
        Diag.log("Konvoi-Pause von \(p.fromName): \(p.name)")
        let first = p.fromName.split(separator: " ").first.map(String.init) ?? p.fromName
        let title = String(localized: "\(first) schlägt eine Pause vor")
        let detail = subtitle(p)
        if CarPlayController.shared.isConnected {
            let yes = CPAlertAction(title: String(localized: "Dabei"), style: .default) { [weak self] _ in
                Task { @MainActor in await self?.answer(p, accept: true) }
            }
            let no = CPAlertAction(title: String(localized: "Nein"), style: .cancel) { [weak self] _ in
                Task { @MainActor in await self?.answer(p, accept: false) }
            }
            let alert = CPNavigationAlert(titleVariants: [title, String(localized: "Pause?")], subtitleVariants: [detail],
                                          image: UIImage(systemName: p.charger ? "bolt.car.fill" : "cup.and.saucer.fill"),
                                          primaryAction: yes, secondaryAction: no, duration: 45)
            if CarPlayUI.shared.alert(alert, priority: .high) { return }
        }
        prompt = p
    }

    func received(_ r: Reply) {
        guard r.id == mine?.id, let friend = app.friend(r.userId) else { return }
        notice(r.accept ? String(localized: "\(friend.firstName) ist bei der Pause dabei")
                        : String(localized: "\(friend.firstName) fährt weiter"))
    }

    /// „Dabei“: Halt als Zwischenstopp; Antwort an alle Freunde (der Vorschlagende hört mit)
    func answer(_ p: Proposal, accept: Bool) async {
        prompt = nil
        guard let me = app.profile?.id else { return }
        await app.hub.broadcast(event: "pause_reply", Reply(id: p.id, userId: me, accept: accept))
        Diag.log("Konvoi-Pause \(accept ? "angenommen" : "abgelehnt"): \(p.name)")
        if accept { await app.navigation.addStop(place(p)) }
    }

    /// „Raststätte Garbsen · 18 km · Schnelllader 150 kW“
    func subtitle(_ p: Proposal) -> String {
        var parts = [p.name]
        if let here = app.location.lastLocation?.coordinate { parts.append(ActivityFormat.distance(here.distance(to: p.coordinate))) }
        if p.charger { parts.append(p.kw.map { String(localized: "Schnelllader \(Int($0)) kW") } ?? String(localized: "mit Ladesäule")) }
        return parts.joined(separator: " · ")
    }

    private func place(_ p: Proposal) -> Place {
        Place(id: "pause-\(p.id.uuidString)", name: p.name, address: nil, coordinate: p.coordinate,
              symbol: p.charger ? "bolt.car.fill" : "cup.and.saucer.fill")
    }

    private func notice(_ text: String) {
        if CarPlayController.shared.isConnected {
            CarPlayController.shared.showNotice(title: [text])
        } else {
            app.show(text, isError: false)
        }
    }
}
