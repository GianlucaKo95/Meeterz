import Foundation
import UIKit
import CarPlay
import CoreLocation
import MapboxNavigationCore
import MapboxNavigationUIKit

/// Ergänzungen wie bei Apple Karten / Google Maps:
/// Hinweise auf der Karte (schnellere Route, Freunde), Tempowarnung und Suche mit Kategorien.
extension CarPlayController {

    // MARK: Hinweise auf der Karte

    /// Die gerade sichtbare Karten-Vorlage (während der Fahrt ersetzt Mapbox die Wurzel durch die Fahrt-Vorlage)
    var alertTemplate: CPMapTemplate? {
        guard isConnected, let controller = manager.interfaceController else { return nil }
        return (controller.rootTemplate as? CPMapTemplate) ?? (controller.topTemplate as? CPMapTemplate)
    }

    /// Kurzer Hinweis, der von selbst wieder verschwindet. Eine offene Frage (schnellere Route) hat Vorrang.
    func showNotice(title: [String], subtitle: [String]? = nil, image: UIImage? = nil, seconds: TimeInterval = 6) {
        guard let template = alertTemplate, template.currentNavigationAlert == nil, fasterRouteAnswer == nil else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { _ in }
        let alert = CPNavigationAlert(titleVariants: title, subtitleVariants: subtitle, image: image,
                                      primaryAction: ok, secondaryAction: nil, duration: seconds)
        template.present(navigationAlert: alert, animated: true)
    }

    // MARK: Schnellere Route (wie Google Maps: fragen statt still wechseln)

    /// Wird von Mapbox gefragt, ob auf eine gefundene schnellere Route gewechselt werden soll.
    /// Ohne CarPlay bleibt es beim automatischen Wechsel; ohne Antwort nach 12 s bleibt die bisherige Route.
    func approveFasterRoute(_ route: NavigationRoute) async -> Bool {
        guard let template = alertTemplate else { return true }
        let remaining = AppModel.shared.navigation.remaining?.duration
        let saved = remaining.map { $0 - route.route.expectedTravelTime } ?? 0
        let minutes = max(1, Int((saved / 60).rounded()))

        answerFasterRoute(false)   // eine ältere, noch offene Frage gilt als „Behalten“
        if template.currentNavigationAlert != nil {
            template.dismissNavigationAlert(animated: false) { _ in }
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            fasterRouteAnswer = (id, continuation)
            let alert = CPNavigationAlert(
                titleVariants: ["Schnellere Route – \(minutes) Min. sparen", "\(minutes) Min. schneller"],
                subtitleVariants: ["Auf die schnellere Route wechseln?"],
                image: UIImage(systemName: "bolt.horizontal.circle.fill"),
                primaryAction: CPAlertAction(title: "Wechseln", style: .default) { [weak self] _ in
                    self?.answerFasterRoute(true)
                },
                secondaryAction: CPAlertAction(title: "Behalten", style: .cancel) { [weak self] _ in
                    self?.answerFasterRoute(false)
                },
                duration: 12
            )
            template.present(navigationAlert: alert, animated: true)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(13))
                self?.answerFasterRoute(false, onlyFor: id)
            }
        }
    }

    func answerFasterRoute(_ accept: Bool, onlyFor id: UUID? = nil) {
        guard let pending = fasterRouteAnswer else { return }
        if let id, pending.id != id { return }
        fasterRouteAnswer = nil
        pending.continuation.resume(returning: accept)
    }

    // MARK: Freunde

    private func avatar(_ friend: FriendRow) -> UIImage {
        AvatarRenderer.image(initials: friend.initials,
                             color: FriendPalette.uiColor(for: friend.friendId),
                             faded: false,
                             photo: AppModel.shared.avatars.image(for: friend.friendId))
    }

    private func firstName(_ friend: FriendRow) -> String {
        friend.displayName.split(separator: " ").first.map(String.init) ?? friend.displayName
    }

    /// Hinweis zu den Momenten des Soundpakets – erscheint zusätzlich zum Schnipsel bzw. der Ansage
    func friendNotice(_ moment: SoundMoment, friend: FriendRow) {
        let name = firstName(friend)
        let title: [String]
        switch moment {
        case .pass: title = ["\(name) fährt gerade an dir vorbei", "\(name) fährt vorbei"]
        case .soon: title = ["\(name) ist in ca. 5 Min. am Treffpunkt", "\(name) in 5 Min. da"]
        case .arrived: title = ["\(name) ist am Treffpunkt angekommen", "\(name) ist da"]
        case .accepted: title = ["\(name) hat dein Treffen angenommen", "\(name) kommt"]
        }
        showNotice(title: title, image: avatar(friend))
    }

    /// Ankunftszeit eines Freundes, der zum selben Ziel unterwegs ist (sein Ziel liegt höchstens 300 m entfernt)
    func friendArrival(_ friendId: UUID, at place: Place) -> Date? {
        guard let route = AppModel.shared.routes.friendRoutes[friendId],
              route.destination.distance(to: place.coordinate) < 300,
              route.eta > Date()
        else { return nil }
        return route.eta
    }

    /// Meldet Freunde, die zum selben Ziel fahren – beim Start und wenn sich ihre Ankunft deutlich verschiebt
    func announceFriendsHeadingToDestination() {
        guard AppModel.shared.navigation.isNavigating, let place = inviteDestination else { return }
        let myEta = AppModel.shared.navigation.eta
        for friend in AppModel.shared.friends.accepted {
            guard let eta = friendArrival(friend.friendId, at: place) else { continue }
            if let last = friendArrivalAnnounced[friend.friendId],
               abs(last.eta.timeIntervalSince(eta)) < 5 * 60 || Date().timeIntervalSince(last.at) < 10 * 60 {
                continue
            }
            friendArrivalAnnounced[friend.friendId] = (eta, Date())
            var subtitle = "Ankunft \(Format.time.string(from: eta))"
            if let myEta {
                let diff = Int((eta.timeIntervalSince(myEta) / 60).rounded())
                if diff > 0 { subtitle += " · \(diff) Min. nach dir" }
                else if diff < 0 { subtitle += " · \(-diff) Min. vor dir" }
                else { subtitle += " · gleichzeitig mit dir" }
            }
            showNotice(title: ["\(firstName(friend)) fährt auch hierher", "\(firstName(friend)) kommt auch"],
                       subtitle: [subtitle], image: avatar(friend), seconds: 8)
            return   // höchstens ein Hinweis auf einmal
        }
    }

    // MARK: Tempowarnung (Schild wird rot, wie bei Google Maps)

    func startSpeedWarning() {
        speedTimer?.invalidate()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateSpeedSigns()
                // alle 30 s: Freunde mit gleichem Ziel prüfen
                if Int(Date().timeIntervalSince1970) % 30 == 0 { self.announceFriendsHeadingToDestination() }
            }
        }
    }

    func stopSpeedWarning() {
        speedTimer?.invalidate()
        speedTimer = nil
        friendArrivalAnnounced = [:]
        answerFasterRoute(false)
    }

    private func updateSpeedSigns() {
        let speed = max(AppModel.shared.location.lastLocation?.speed ?? -1, -1) * 3.6   // km/h, < 0 = unbekannt
        let views = [manager.carPlayNavigationViewController?.speedLimitView,
                     manager.carPlayMapViewController?.speedLimitView].compactMap { $0 }
        for view in views {
            var speeding = false
            if speed >= 0, let limit = view.speedLimit?.converted(to: .kilometersPerHour).value, limit > 0 {
                speeding = speed > limit + 3      // kleine Toleranz gegen GPS-Schwankungen
            }
            let back: UIColor = speeding ? UIColor(red: 0.90, green: 0.16, blue: 0.16, alpha: 1) : .white
            let text: UIColor = speeding ? .white : .black
            if view.signBackColor != back { view.signBackColor = back }
            if view.textColor != text { view.textColor = text }
        }
    }

    // MARK: Suche mit Kategorien

    /// Startseite der Suche: Tastatur/Diktat und Kategorien. Während der Fahrt wird entlang der Route gesucht.
    func showSearchHub() {
        let navigating = AppModel.shared.navigation.isNavigating
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)

        let search = CPListItem(text: "Suchen", detailText: "Adresse oder Ort eingeben",
                                image: UIImage(systemName: "magnifyingglass", withConfiguration: config))
        search.handler = { [weak self] _, done in self?.showSearch(); done() }

        let categories: [CPListItem] = SearchService.Stopover.allCases.map { kind in
            let item = CPListItem(text: kind.title, detailText: navigating ? "Entlang der Route" : "In der Nähe",
                                  image: UIImage(systemName: kind.symbol, withConfiguration: config))
            item.handler = { [weak self] _, done in self?.showStopovers(kind); done() }
            return item
        }

        let template = CPListTemplate(title: navigating ? "Stopp hinzufügen" : "Suche", sections: [
            CPListSection(items: [search]),
            CPListSection(items: categories, header: navigating ? "Unterwegs" : "Kategorien", sectionIndexTitle: nil),
        ])
        manager.interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showStopovers(_ kind: SearchService.Stopover) {
        let template = CPListTemplate(title: kind.title, sections: [
            CPListSection(items: [CPListItem(text: "Wird gesucht …", detailText: nil)]),
        ])
        manager.interfaceController?.pushTemplate(template, animated: true, completion: nil)

        Task { @MainActor [weak self, weak template] in
            guard let self, let template else { return }
            guard let me = AppModel.shared.location.lastLocation?.coordinate else {
                template.updateSections([CPListSection(items: [CPListItem(text: "Standort unbekannt", detailText: nil)])])
                return
            }
            let ahead = AppModel.shared.navigation.isNavigating ? routeAhead(from: me) : nil
            var places: [Place]
            do {
                places = try await SearchService.stopovers(kind, near: me, route: ahead)
            } catch {
                template.updateSections([CPListSection(items: [
                    CPListItem(text: (error as? LocalizedError)?.errorDescription ?? "Die Suche ist gerade nicht erreichbar.", detailText: nil),
                ])])
                return
            }
            // Entlang der Route: nur, was noch vor mir liegt – nach Reihenfolge auf der Strecke
            if let ahead {
                let ranked = places.compactMap { place -> (Place, Int)? in
                    guard let index = Self.nearestIndex(of: place.coordinate, in: ahead),
                          ahead[index].distance(to: place.coordinate) < 3_000 else { return nil }
                    return (place, index)
                }
                places = ranked.sorted { $0.1 < $1.1 }.map(\.0)
            } else {
                places.sort { $0.coordinate.distance(to: me) < $1.coordinate.distance(to: me) }
            }
            let items: [CPListItem] = places.prefix(CPListTemplate.maximumItemCount).map { place in
                let away = Format.distance(place.coordinate.distance(to: me))
                let item = CPListItem(text: place.name, detailText: [away, place.address].compactMap { $0 }.joined(separator: " · "))
                item.handler = { [weak self] _, done in
                    self?.manager.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                    self?.go(to: place)
                    done()
                }
                return item
            }
            template.updateSections([CPListSection(items: items.isEmpty
                ? [CPListItem(text: "Nichts gefunden", detailText: nil)] : items)])
        }
    }

    /// Restliche Strecke ab der aktuellen Position, auf höchstens 300 Punkte ausgedünnt
    private func routeAhead(from me: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        guard let coords = navigationProvider.mapboxNavigation.tripSession().currentNavigationRoutes?
                .mainRoute.route.shape?.coordinates,
              coords.count > 1,
              let start = Self.nearestIndex(of: me, in: coords)
        else { return nil }
        let rest = Array(coords[start...])
        guard rest.count > 1 else { return nil }
        let step = max(1, rest.count / 300)
        var thinned = stride(from: 0, to: rest.count, by: step).map { rest[$0] }
        if let last = rest.last, thinned.last.map({ $0.distance(to: last) > 1 }) ?? true { thinned.append(last) }
        return thinned
    }

    private static func nearestIndex(of point: CLLocationCoordinate2D, in coords: [CLLocationCoordinate2D]) -> Int? {
        coords.indices.min { coords[$0].distance(to: point) < coords[$1].distance(to: point) }
    }
}
