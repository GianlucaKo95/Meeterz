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

    /// Die Karten-Vorlage, auf der ein Hinweis gefahrlos erscheinen darf – sonst nil.
    ///
    /// Ein Hinweis auf eine Vorlage, die gerade ausgetauscht wird (Mapbox baut beim Start und Ende der Navigation
    /// und am Ziel neue Vorlagen) oder die unter einer Liste bzw. einem Ankunftsfenster liegt, legte die große
    /// CarPlay-Ansicht lahm – das Dashboard lief weiter. Deshalb nur, wenn die Karte ganz oben liegt und gerade
    /// kein Vorlagenwechsel läuft.
    var alertTemplate: CPMapTemplate? {
        guard isConnected, let controller = manager.interfaceController,
              Date() >= alertsPausedUntil,
              let root = controller.rootTemplate as? CPMapTemplate,
              controller.topTemplate === root,
              controller.presentedTemplate == nil else { return nil }
        return root
    }

    /// Hinweise kurz zurückhalten (Vorlagenwechsel der Navigation)
    func pauseAlerts(seconds: TimeInterval = 5) {
        alertsPausedUntil = Date().addingTimeInterval(seconds)
        CarPlayUI.shared.clearAlerts()
    }

    /// Kurzer Hinweis, der von selbst wieder verschwindet. Eine offene Frage (schnellere Route) hat Vorrang.
    func showNotice(title: [String], subtitle: [String]? = nil, image: UIImage? = nil, seconds: TimeInterval = 6) {
        guard let template = alertTemplate, template.currentNavigationAlert == nil, fasterRouteAnswer == nil else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { _ in }
        let alert = CPNavigationAlert(titleVariants: title, subtitleVariants: subtitle, image: image,
                                      primaryAction: ok, secondaryAction: nil, duration: seconds)
        CarPlayUI.shared.alert(alert)
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
            guard CarPlayUI.shared.alert(alert, replacing: true) else {
                answerFasterRoute(true, onlyFor: id)   // Frage konnte nicht erscheinen: wie ohne CarPlay wechseln
                return
            }
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
                if Int(Date().timeIntervalSince1970) % 30 == 0 {
                    Passengers.shared.check { self.askPassenger($0) }
                    self.announceFriendsHeadingToDestination()
                    // Konvoi: anhalten, zurückfallen, andere Strecke
                    ConvoyTracker.shared.check { text, friend in
                        let image = AvatarRenderer.image(initials: friend.initials, color: FriendPalette.uiColor(for: friend.friendId),
                                                         faded: false, photo: AppModel.shared.avatars.image(for: friend.friendId))
                        self.showNotice(title: [text], image: image)
                    }
                }
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
        CarPlayUI.shared.push(template, animated: true)
    }

    /// `limitMeters`: nur Orte bis zu diesem Punkt der Route (z. B. so weit der Akku reicht)
    func showStopovers(_ kind: SearchService.Stopover, title: String? = nil, limitMeters: Double? = nil) {
        let template = CPListTemplate(title: title ?? kind.title, sections: [
            CPListSection(items: [CPListItem(text: "Wird gesucht …", detailText: nil)]),
        ])
        CarPlayUI.shared.push(template, animated: true)

        Task { @MainActor [weak self, weak template] in
            guard let self, let template else { return }
            guard let me = AppModel.shared.location.lastLocation?.coordinate else {
                template.updateSections([CPListSection(items: [CPListItem(text: "Standort unbekannt", detailText: nil)])])
                return
            }
            var ahead = AppModel.shared.navigation.isNavigating ? routeAhead(from: me) : nil
            // Kilometer entlang der Strecke je Routenpunkt
            var along: [Double] = [0]
            if let route = ahead {
                for (a, b) in zip(route, route.dropFirst()) { along.append(along.last! + a.distance(to: b)) }
                if let limitMeters, let cut = along.firstIndex(where: { $0 > limitMeters }), cut > 1 {
                    ahead = Array(route[..<cut])
                    along = Array(along[..<cut])
                }
            }
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
                var away = Format.distance(place.coordinate.distance(to: me))
                if let route = ahead, let i = Self.nearestIndex(of: place.coordinate, in: route), i < along.count {
                    away = "nach \(Format.distance(along[i]))"   // entlang der Route
                }
                let item = CPListItem(text: place.name, detailText: [away, place.address].compactMap { $0 }.joined(separator: " · "))
                item.handler = { [weak self] _, done in self?.select(place, done: done) }
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

// MARK: - Kurznachrichten in CarPlay

extension CarPlayController {
    /// Wen betrifft dieses Ziel? Angenommene Treffen hier und Freunde, die auch hierher fahren.
    func meetupPartners(at place: Place) -> (ids: [UUID], meetupId: UUID?) {
        let app = AppModel.shared
        let meetups = app.meetups.accepted.filter { $0.coordinate.distance(to: place.coordinate) < 300 }
        var ids = meetups.map(\.otherId)
        for friend in app.friends.accepted where friendArrival(friend.friendId, at: place) != nil {
            ids.append(friend.friendId)
        }
        var seen = Set<UUID>()
        return (ids.filter { seen.insert($0).inserted }, meetups.first?.id)
    }

    /// Liste vorgefertigter Antworten; ein Tippen sendet an alle Empfänger
    func showQuickReplies(to ids: [UUID], meetupId: UUID?, replace: Bool = false) {
        let eta = AppModel.shared.navigation.isNavigating ? AppModel.shared.navigation.eta : nil
        let items: [CPListItem] = MessagesStore.quickReplies(eta: eta).map { text in
            let item = CPListItem(text: text, detailText: nil)
            item.handler = { [weak self] _, done in
                Task { @MainActor in
                    let sent = await AppModel.shared.messages.send(text, to: ids, meetupId: meetupId)
                    CarPlayUI.shared.popToRoot(animated: true)
                    done()
                    self?.showNotice(title: [sent > 0 ? "Gesendet: „\(text)“" : "Nachricht nicht gesendet"])
                }
            }
            return item
        }
        let names = ids.compactMap { AppModel.shared.friend($0)?.displayName.split(separator: " ").first.map(String.init) }
        let template = CPListTemplate(title: names.isEmpty ? "Bescheid geben" : "An " + names.joined(separator: ", "),
                                      sections: [CPListSection(items: items)])
        CarPlayUI.shared.push(template, animated: true)
    }

    /// Eingehende Nachricht: kurzer Hinweis mit „Antworten“
    func messageReceived(_ m: MessagesStore.Message) {
        guard let template = alertTemplate, template.currentNavigationAlert == nil, fasterRouteAnswer == nil else { return }
        let image = AppModel.shared.friend(m.otherId).map { f in
            AvatarRenderer.image(initials: f.initials, color: FriendPalette.uiColor(for: f.friendId),
                                 faded: false, photo: AppModel.shared.avatars.image(for: f.friendId))
        }
        let reply = CPAlertAction(title: "Antworten", style: .default) { [weak self] _ in
            Task { @MainActor in self?.showQuickReplies(to: [m.otherId], meetupId: m.meetupId) }
        }
        let ok = CPAlertAction(title: "OK", style: .cancel) { _ in }
        let alert = CPNavigationAlert(titleVariants: ["\(m.firstName): \(m.body)", m.firstName],
                                      subtitleVariants: m.automatic ? ["Automatische Nachricht"] : nil,
                                      image: image, primaryAction: reply, secondaryAction: ok, duration: 12)
        CarPlayUI.shared.alert(alert)
    }
}

// MARK: - E-Auto: Ladestopp, wenn der Akku nicht reicht

/// Angaben zum E-Auto (Einstellungen; den Akkustand stellt man beim Losfahren in CarPlay ein)
enum EVSettings {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "ev.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "ev.enabled") }
    }
    /// Gewähltes Fahrzeug (Katalog oder „Andere“ mit eigenen Werten)
    static var vehicle: EVVehicle? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "ev.vehicle") else { return nil }
            return try? JSONDecoder().decode(EVVehicle.self, from: data)
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "ev.vehicle")
        }
    }

    /// Reichweite bei 100 % in km: aus dem Fahrzeug (Batterie ÷ Verbrauch), sonst der eingestellte Wert
    static var rangeKm: Double {
        get { vehicle.map(\.rangeKm) ?? (UserDefaults.standard.object(forKey: "ev.rangeKm") as? Double ?? 350) }
        set { UserDefaults.standard.set(newValue, forKey: "ev.rangeKm") }
    }
    /// Akkustand in Prozent: live aus dem Auto, sonst der zuletzt gewählte Wert
    @MainActor static var chargePercent: Double {
        get { AppModel.shared.vehicle.liveSoc ?? UserDefaults.standard.object(forKey: "ev.charge") as? Double ?? 80 }
        set { UserDefaults.standard.set(newValue, forKey: "ev.charge") }
    }
    /// Bis hierhin kommt man mit 10 % Reserve (Meter)
    @MainActor static var usableMeters: Double { max(0, rangeKm * 1000 * (chargePercent - 10) / 100) }
}

extension CarPlayController {
    /// Nach dem Start der Navigation: reicht der Akku bis zum Ziel? Sonst Hinweis mit Ladesäulen.
    func checkCharge() {
        // Mit gewähltem Fahrzeug: richtiger Ladeplan (wie ABRP) statt grober Reichweitenprüfung
        if EVSettings.enabled, EVSettings.vehicle != nil {
            Task { @MainActor in await self.offerChargePlan() }
            return
        }
        guard EVSettings.enabled, let remaining = AppModel.shared.navigation.remaining?.distance else { return }
        let usable = EVSettings.usableMeters
        guard remaining > usable else { return }
        Diag.log("E-Auto: Route \(Int(remaining / 1000)) km, Akku reicht ca. \(Int(usable / 1000)) km")
        guard let template = alertTemplate, template.currentNavigationAlert == nil else { return }
        let show = CPAlertAction(title: "Ladesäulen", style: .default) { [weak self] _ in
            Task { @MainActor in self?.showChargingStops() }
        }
        let later = CPAlertAction(title: "Später", style: .cancel) { _ in }
        let alert = CPNavigationAlert(
            titleVariants: ["Ladestopp nötig – Akku reicht ca. \(Format.distance(usable))", "Ladestopp nötig"],
            subtitleVariants: ["Bei \(Int(EVSettings.chargePercent)) % Akku und 10 % Reserve"],
            image: UIImage(systemName: "bolt.car.fill"),
            primaryAction: show, secondaryAction: later, duration: 15)
        CarPlayUI.shared.alert(alert)
    }

    /// Nach dem Start: Ladeplan für die laufende Route; fehlen Ladestopps, mit einem Tipp übernehmen
    func offerChargePlan() async {
        guard let routes = navigationProvider.mapboxNavigation.tripSession().currentNavigationRoutes,
              routes.mainRoute.route.legs.count == 1,                         // führt schon über Zwischenziele
              let result = await EVSettings.plan(for: routes.mainRoute.route) else { return }
        guard let template = alertTemplate, template.currentNavigationAlert == nil else { return }
        switch result {
        case .success(let plan) where plan.direct:
            Diag.log("Ladeplan: \(plan.summary)")
        case .success(let plan):
            Diag.log("Ladeplan: \(plan.summary) – \(plan.stops.map { "\($0.site.title) \(Int($0.arrivalPercent))→\(Int($0.departurePercent)) %" })")
            let take = CPAlertAction(title: "Übernehmen", style: .default) { _ in
                Task { @MainActor in await Self.adoptChargePlan(plan) }
            }
            let later = CPAlertAction(title: "Nein", style: .cancel) { _ in }
            let first = plan.stops[0]
            let alert = CPNavigationAlert(
                titleVariants: [plan.summary, "\(plan.stops.count) Ladestopp\(plan.stops.count == 1 ? "" : "s") nötig"],
                subtitleVariants: ["Erster: \(first.site.title), \(first.site.powerKnown ? "\(Int(first.site.maxKW)) kW, " : "")\(Int((first.chargeTime / 60).rounded())) Min."],
                image: UIImage(systemName: "bolt.car.fill"),
                primaryAction: take, secondaryAction: later, duration: 20)
            CarPlayUI.shared.alert(alert)
        case .failure(.unreachable(let km)):
            let ok = CPAlertAction(title: "Ladesäulen", style: .default) { [weak self] _ in
                Task { @MainActor in self?.showChargingStops() }
            }
            let alert = CPNavigationAlert(
                titleVariants: ["Kein Ladeplan möglich – Reichweite ca. \(Int(km)) km"],
                subtitleVariants: ["Keine passenden Schnelllader mit Leistungsangabe entlang der Route"],
                image: UIImage(systemName: "bolt.car.fill"),
                primaryAction: ok, secondaryAction: nil, duration: 15)
            CarPlayUI.shared.alert(alert)
        case .failure(.noVehicle):
            break
        }
    }

    /// Ladestopps als Zwischenziele in die laufende Navigation einbauen
    static func adoptChargePlan(_ plan: ChargePlanner.Plan) async {
        let nav = AppModel.shared.navigation
        guard let destination = nav.destination,
              let routes = await nav.calculate(to: destination, via: plan.stops.map(\.place), mode: .car) else { return }
        navigationProvider.mapboxNavigation.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)
        ChargingSession.shared.plan = plan
        Diag.log("Ladeplan übernommen (CarPlay): \(plan.summary)")
    }

    /// Ladesäulen entlang der Route, bis zu dem Punkt, an dem der Akku knapp wird
    func showChargingStops() {
        let limit = EVSettings.usableMeters
        showStopovers(.charging, title: "Laden bis km \(Int(limit / 1000))", limitMeters: limit > 1_000 ? limit : nil)
    }

    /// Akkustand beim Losfahren einstellen (CarPlay-Liste)
    func showChargePicker() {
        let items: [CPListItem] = stride(from: 100, through: 10, by: -10).map { value in
            let current = Int(EVSettings.chargePercent) == value
            let item = CPListItem(text: "\(value) %", detailText: current ? "aktuell" : "ca. \(Int(EVSettings.rangeKm * Double(value) / 100)) km")
            item.handler = { [weak self] _, done in
                EVSettings.chargePercent = Double(value)
                CarPlayUI.shared.pop(animated: true)
                done()
                self?.checkCharge()
            }
            return item
        }
        CarPlayUI.shared.push(CPListTemplate(title: "Akkustand", sections: [CPListSection(items: items)]), animated: true)
    }

    /// Abschnitt „E-Auto“ für die „Mehr“-Liste
    func chargeSection() -> CPListSection? {
        guard EVSettings.enabled else { return nil }
        let live = AppModel.shared.vehicle.liveSoc != nil
        let battery = CPListItem(text: live ? "Akku (live): \(Int(EVSettings.chargePercent)) %" : "Akku beim Losfahren: \(Int(EVSettings.chargePercent)) %",
                                 detailText: "Reicht ca. \(Format.distance(EVSettings.usableMeters))",
                                 image: UIImage(systemName: "battery.75percent"))
        // Mit Live-Daten gibt es nichts einzustellen
        battery.handler = { [weak self] _, done in if !live { self?.showChargePicker() }; done() }
        let stops = CPListItem(text: "Ladesäulen entlang der Route", detailText: nil, image: UIImage(systemName: "bolt.car.fill"))
        stops.handler = { [weak self] _, done in self?.showChargingStops(); done() }
        return CPListSection(items: [battery, stops], header: "E-Auto", sectionIndexTitle: nil)
    }
}
