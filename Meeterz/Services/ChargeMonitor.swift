import Foundation
import UIKit
import CarPlay
import CoreLocation
import MapboxNavigationCore

/// Ladeplan unterwegs nachführen: alle 2 Minuten mit dem Live-Akkustand für die Reststrecke neu planen.
/// Passt der neue Plan nicht mehr zur gefahrenen Route (Stopp fehlt, anderer Stopp, Stopp unnötig), Hinweis mit „Übernehmen“.
@MainActor
final class ChargeMonitor {
    static let shared = ChargeMonitor()

    private var timer: Timer?
    private var lastAlert = Date.distantPast
    private var lastSignature = ""

    /// Bezugspunkt der Prognose ohne Live-Daten: Akkustand an einer Stelle der aktuellen Route.
    /// Nach einer Neuberechnung beginnt die gefahrene Strecke der neuen Route wieder bei 0 – vorher wurde dann vom
    /// Akkustand beim Fahrtstart aus gerechnet und der bis dahin verbrauchte Strom „vergessen“ (Ziel-% zu hoch).
    private var anchorSoc: Double = 0
    private var anchorTraveled: Double = 0
    /// Zuletzt geschätzter Akkustand unterwegs (%)
    private(set) var lastEstimate: Double?
    /// Akkustand bei Ankunft am Ziel bzw. am nächsten Stopp (für die Live-Aktivität)
    private(set) var arrivalPercent: Double?
    private var lastLogged = ""
    private var profileKey = ""
    private var profile: ChargePlanner.Profile?
    /// Zuletzt gesehener Abschnitt (für „Ladestopp passiert“ ohne Live-Daten)
    private var legMark: (route: String, leg: Int) = ("", 0)

    func start() {
        stop()
        guard EVSettings.enabled, EVSettings.vehicle != nil else { return }
        anchorSoc = EVSettings.chargePercent
        anchorTraveled = 0
        lastEstimate = nil
        legMark = ("", 0)
        arrivalPercent = nil
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in await ChargeMonitor.shared.check() }
        }
        // Erste Prognose, sobald die Route steht
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            ChargeMonitor.shared.updateForecast()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSignature = ""
        profile = nil
        profileKey = ""
        CarPlayBatteryChip.shared.hide()
    }

    /// Prognose für das Akku-Kästchen in CarPlay: Akkustand am nächsten Zwischenziel (Ladestopp) bzw. am Ziel
    func updateForecast() {
        guard EVSettings.enabled, let vehicle = EVSettings.vehicle,
              let routes = navigationProvider.mapboxNavigation.tripSession().currentNavigationRoutes,
              let progress = navigationProvider.mapboxNavigation.navigation().currentRouteProgress?.routeProgress
        else { CarPlayBatteryChip.shared.hide(); return }
        let route = routes.mainRoute.route
        // Eindeutig je Route (Mapbox-Routen-ID), nicht nur Länge und Abschnitte – zwei Routen können gleich lang sein
        // Höhe und Wetter, sobald geladen (dann einmal neu rechnen)
        let conditions = RouteConditionsService.shared.cached(for: route)
        if conditions == nil { RouteConditionsService.shared.prefetch(route) }
        let key = "\(routes.mainRoute.routeId)-\(conditions != nil)"
        let traveled = progress.distanceTraveled
        if key != profileKey {
            let settings = EVSettings.plannerSettings
            profile = ChargePlanner.profile(of: route, vehicle: vehicle, temperature: settings.temperature, factors: settings.factors,
                                            conditions: conditions)
            // Neue Route (auch nach Neuberechnung): ab dem zuletzt geschätzten Stand weiterrechnen
            if !profileKey.isEmpty, let lastEstimate { anchorSoc = lastEstimate }
            anchorTraveled = traveled
            profileKey = key
        }
        guard let profile else { return }
        let pct = { (kwh: Double) in kwh / vehicle.battery * 100 }
        let live = (AppModel.shared.vehicle.status?.age ?? .infinity) < 5 * 60 ? AppModel.shared.vehicle.liveSoc : nil
        if let live { anchorSoc = live; anchorTraveled = traveled }
        // Ohne Live-Daten: Ladestopp passiert → ab dort mit dem geplanten Ladestand weiterrechnen
        let routeId = "\(routes.mainRoute.routeId)"
        if live == nil, legMark.route == routeId, progress.legIndex > legMark.leg,
           progress.legIndex - 1 < route.legs.count,
           let passed = route.legs[progress.legIndex - 1].destination?.coordinate,
           let stop = ChargingSession.shared.plan?.stops.first(where: { $0.site.coordinate.distance(to: passed) < 300 }) {
            anchorSoc = stop.departurePercent
            anchorTraveled = traveled
            Diag.log("Ladestopp \(stop.site.title) passiert – weiter mit geplanten \(Int(stop.departurePercent)) %")
        }
        legMark = (routeId, progress.legIndex)
        let now = anchorSoc - pct(profile.energy(from: anchorTraveled, to: max(traveled, anchorTraveled)))
        lastEstimate = now
        // Ende des aktuellen Abschnitts: Zwischenziel oder Ziel
        var end = 0.0
        for (i, leg) in route.legs.enumerated() {
            end += leg.distance
            if i >= progress.legIndex { break }
        }
        let last = progress.legIndex >= route.legs.count - 1
        let arrival = now - pct(profile.energy(from: traveled, to: end))
        let limit = last ? EVSettings.arrivalPercent : EVSettings.minAtChargerPercent
        arrivalPercent = arrival
        // Zum Nachprüfen: Modell gegen die Reichweite des Autos (km je % laut Auto)
        let restKm = max(0, end - traveled) / 1000
        let modelPer100 = restKm > 0.5 ? profile.energy(from: traveled, to: end) / restKm * 100 : 0
        let carArrival = AppModel.shared.vehicle.liveRangeKm.flatMap { r in (live ?? now) > 1 ? now - restKm / (r / (live ?? now)) : nil }
        let line = "Akku-Prognose: jetzt \(Int(now.rounded())) % (\(live != nil ? "live" : "geschätzt")), \(last ? "Ziel" : "Stopp") \(Int(arrival.rounded())) %, Rest \(Int(restKm)) km, Modell \(String(format: "%.1f", modelPer100)) kWh/100 km" + (carArrival.map { ", nach Auto-Reichweite \(Int($0.rounded())) %" } ?? "")
        if line != lastLogged { lastLogged = line; Diag.log(line) }
        CarPlayBatteryChip.shared.show(label: last ? String(localized: "Ziel") : String(localized: "Stopp"), percent: arrival, low: arrival < limit, live: live != nil)
    }

    /// `pause`: gleich nach dem Einfügen einer Konvoi-Pause – auch ohne Live-Wert (dann mit der Schätzung), ohne
    /// Sperrzeit, und mit Rückmeldung, wie viel in der Pause geladen wird
    func check(pause: Place? = nil) async {
        updateForecast()
        let fresh = (AppModel.shared.vehicle.status?.age ?? .infinity) < 4 * 60
        let live = fresh ? AppModel.shared.vehicle.liveSoc : nil
        // Ohne Live-Daten mit der Schätzung (Verbrauchsmodell, an Ladestopps auf den geplanten Stand gesetzt)
        guard EVSettings.enabled, let vehicle = EVSettings.vehicle,
              let soc = live ?? lastEstimate ?? (pause != nil ? EVSettings.chargePercent : nil),
              let routes = navigationProvider.mapboxNavigation.tripSession().currentNavigationRoutes,
              let progress = navigationProvider.mapboxNavigation.navigation().currentRouteProgress?.routeProgress
        else { return }
        let route = routes.mainRoute.route
        let routeId = routes.mainRoute.routeId
        let traveled = progress.distanceTraveled
        var settings = EVSettings.plannerSettings
        // Selbst gewählte Halte (Konvoi-Pause, Treffpunkt) fest einplanen – an einer Ladesäule wird dort nach Bedarf geladen
        var legEnd = 0.0
        for (i, leg) in route.legs.enumerated().dropLast() {
            legEnd += leg.distance
            guard i >= progress.legIndex, let w = leg.destination, AppModel.shared.navigation.isFixedStop(w.coordinate) else { continue }
            let site = ChargeSites.all.filter { $0.coordinate.distance(to: w.coordinate) < 150 }.max { $0.plannedKW < $1.plannedKW }
            settings.fixed.append(.init(site: site ?? ChargeSite(coordinate: w.coordinate, maxKW: 0, points: 0, name: w.name ?? "",
                                                                 operatorName: "", city: ""),
                                        along: legEnd - traveled, offset: 0, fixed: true, canCharge: site != nil))
        }
        settings.availability = await ChargeStatusService.shared.availability(along: route)
        settings.conditions = await RouteConditionsService.shared.conditions(for: route)
        let result = await Task.detached(priority: .utility) {
            let rest = ChargePlanner.profile(of: route, vehicle: vehicle, temperature: settings.temperature,
                                             factors: settings.factors, conditions: settings.conditions).suffix(from: traveled)
            return ChargePlanner.plan(profile: rest, vehicle: vehicle, startPercent: soc, settings: settings,
                                      sites: ChargeSites.all)
        }.value
        // Während der Abfrage und Berechnung kann die Navigation geendet oder die Route gewechselt haben:
        // dann kein Hinweis zu einer Route, die es nicht mehr gibt
        guard AppModel.shared.navigation.isNavigating,
              navigationProvider.mapboxNavigation.tripSession().currentNavigationRoutes?.mainRoute.routeId == routeId
        else { Diag.log("Ladeplan unterwegs verworfen: Route inzwischen gewechselt oder beendet"); return }

        // Zwischenziele der laufenden Route, die noch vor mir liegen (bereits übernommene Ladestopps)
        let legIndex = progress.legIndex
        let upcoming = route.legs.enumerated().dropLast()
            .filter { $0.offset >= legIndex }
            .compactMap { $0.element.destination?.coordinate }
            .filter { !AppModel.shared.navigation.isFixedStop($0) }   // eigene Halte gehören nicht zum Ladeplan

        let message: (title: String, subtitle: String, plan: ChargePlanner.Plan?)?
        switch result {
        case .failure(.unreachable(let km)):
            message = (String(localized: "Akku reicht nicht bis zum Ziel"), String(localized: "Reichweite ca. \(Int(EVSettings.rangeForDisplay(planned: km))) km – Ladesäulen unter „Mehr“"), nil)
        case .failure(.noVehicle):
            message = nil
        case .success(let plan):
            let planned = plan.stops.filter { !$0.fixed }.map(\.site.coordinate)
            let matches = planned.count == upcoming.count
                && zip(planned, upcoming).allSatisfy { $0.distance(to: $1) < 600 }
            if matches || (plan.direct && upcoming.isEmpty) {
                message = nil
            } else if planned.isEmpty, upcoming.isEmpty {
                message = nil   // nur noch an der Pause laden – passt zur Route
            } else if planned.isEmpty {
                message = (String(localized: "Ladestopp nicht mehr nötig"),
                           plan.stops.contains(where: \.fixed) ? String(localized: "Laden in der Pause reicht · Ankunft mit \(Int(plan.arrivalPercent.rounded())) %")
                                                               : String(localized: "Ankunft mit \(Int(plan.arrivalPercent.rounded())) % auch ohne Laden"), plan)
            } else {
                let first = plan.stops.first { !$0.fixed } ?? plan.stops[0]
                message = (String(localized: "Neuer Ladeplan: \(plan.summary)"),
                           String(localized: "Nächster Stopp: \(first.site.title) in \(Int(first.distanceFromStart / 1000)) km"), plan)
            }
        }
        // Nach einer Konvoi-Pause: sagen, was dort geladen wird (oder dass ein weiterer Stopp nötig ist)
        if let pause, case .success(let plan) = result {
            Diag.log("Ladeplan mit Pause \(pause.name): \(plan.summary)")
            ChargingSession.shared.plan = plan   // geplanter Ladestand an der Pause (ohne Live-Daten weiterrechnen)
            lastSignature = ""
            lastAlert = .distantPast
            if message == nil {
                let atPause = plan.stops.first { $0.fixed && $0.site.coordinate.distance(to: pause.coordinate) < 300 }
                let rest = plan.stops.filter { !$0.fixed }.count
                let after = rest == 0 ? String(localized: "danach direkt ans Ziel, Ankunft mit \(Int(plan.arrivalPercent.rounded())) %")
                    : rest == 1 ? String(localized: "danach noch ein Ladestopp") : String(localized: "danach noch \(rest) Ladestopps")
                if let atPause {
                    notice(String(localized: "In der Pause laden auf \(Int(atPause.departurePercent.rounded())) %"),
                           String(localized: "ca. \(max(1, Int((atPause.chargeTime / 60).rounded()))) Min. · \(after)"))
                } else {
                    notice(String(localized: "In der Pause muss nicht geladen werden"), after)
                }
                return
            }
        }
        guard let message else { return }
        // Nicht dauernd melden: gleicher Vorschlag nur einmal, sonst höchstens alle 10 Minuten
        let signature = message.title + (message.plan?.stops.map { "\($0.site.coordinate.latitude)" }.joined() ?? "")
        guard signature != lastSignature, Date().timeIntervalSince(lastAlert) > 10 * 60 else { return }
        lastSignature = signature
        lastAlert = Date()
        Diag.log("Ladeplan unterwegs (\(Int(soc)) %): \(message.title)")
        present(message.title, message.subtitle, plan: message.plan)
    }

    private func notice(_ title: String, _ subtitle: String) {
        if CarPlayController.shared.isConnected { CarPlayController.shared.showNotice(title: [title], subtitle: [subtitle], seconds: 10) }
        else { AppModel.shared.show("\(title) – \(subtitle)", isError: false) }
    }

    private func present(_ title: String, _ subtitle: String, plan: ChargePlanner.Plan?) {
        let carPlay = CarPlayController.shared
        guard carPlay.isConnected, let template = carPlay.alertTemplate, template.currentNavigationAlert == nil else {
            AppModel.shared.show("\(title) – \(subtitle)", isError: plan == nil)
            return
        }
        let primary: CPAlertAction
        if let plan {
            primary = CPAlertAction(title: String(localized: "Übernehmen"), style: .default) { _ in
                Task { @MainActor in await CarPlayController.adoptChargePlan(plan) }
            }
        } else {
            primary = CPAlertAction(title: String(localized: "Ladesäulen"), style: .default) { _ in
                Task { @MainActor in carPlay.showChargingStops() }
            }
        }
        let alert = CPNavigationAlert(titleVariants: [title], subtitleVariants: [subtitle],
                                      image: UIImage(systemName: "bolt.car.fill"),
                                      primaryAction: primary,
                                      secondaryAction: CPAlertAction(title: String(localized: "Nein"), style: .cancel) { _ in },
                                      duration: 20)
        if !CarPlayUI.shared.alert(alert, priority: plan == nil ? .high : .normal) { AppModel.shared.show("\(title) – \(subtitle)", isError: plan == nil) }
    }
}


/// Kleines Akku-Kästchen über der CarPlay-Karte während der Fahrt: „Ziel 21 %“ bzw. „Stopp 18 %“
@MainActor
final class CarPlayBatteryChip {
    static let shared = CarPlayBatteryChip()
    private var label: UILabel?

    func show(label text: String, percent: Double, low: Bool, live: Bool) {
        let carPlay = CarPlayController.shared
        guard carPlay.isConnected, let host = carPlay.manager.carPlayNavigationViewController?.view else { hide(); return }
        let l = label ?? UILabel()
        if l.superview !== host {
            l.removeFromSuperview()
            l.font = .systemFont(ofSize: 15, weight: .bold)
            l.textAlignment = .center
            l.layer.cornerRadius = 14
            l.layer.masksToBounds = true
            l.isUserInteractionEnabled = false
            host.addSubview(l)
            label = l
        }
        let value = Int(percent.rounded())
        l.text = "\(live ? "🔋" : "≈") \(text) \(max(value, 0)) %"
        l.textColor = low ? .white : UIColor(red: 0.024, green: 0.165, blue: 0.196, alpha: 1)
        l.backgroundColor = low ? UIColor(red: 0.85, green: 0.18, blue: 0.21, alpha: 0.95) : Theme.mintUI.withAlphaComponent(0.95)
        let size = CGSize(width: l.intrinsicContentSize.width + 22, height: 28)
        let safe = host.bounds.inset(by: host.safeAreaInsets)
        // unten rechts, links neben der Knopfleiste
        l.frame = CGRect(x: safe.maxX - size.width - 64, y: safe.maxY - size.height - 10, width: size.width, height: size.height)
    }

    func hide() {
        label?.removeFromSuperview()
        label = nil
    }
}
