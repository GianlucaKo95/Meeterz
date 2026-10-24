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

    /// Akkustand beim Start der Fahrt (für die Prognose ohne Live-Daten)
    private var startSoc: Double = 0
    private var profileKey = ""
    private var profile: ChargePlanner.Profile?

    func start() {
        stop()
        guard EVSettings.enabled, EVSettings.vehicle != nil else { return }
        startSoc = EVSettings.chargePercent
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
        let key = "\(route.distance)-\(route.legs.count)"
        if key != profileKey {
            let settings = EVSettings.plannerSettings
            profile = ChargePlanner.profile(of: route, vehicle: vehicle, temperature: settings.temperature, factors: settings.factors)
            profileKey = key
        }
        guard let profile else { return }
        let traveled = progress.distanceTraveled
        let pct = { (kwh: Double) in kwh / vehicle.battery * 100 }
        let live = (AppModel.shared.vehicle.status?.age ?? .infinity) < 5 * 60 ? AppModel.shared.vehicle.liveSoc : nil
        let now = live ?? (startSoc - pct(profile.energy(from: 0, to: traveled)))
        // Ende des aktuellen Abschnitts: Zwischenziel oder Ziel
        var end = 0.0
        for (i, leg) in route.legs.enumerated() {
            end += leg.distance
            if i >= progress.legIndex { break }
        }
        let last = progress.legIndex >= route.legs.count - 1
        let arrival = now - pct(profile.energy(from: traveled, to: end))
        let limit = last ? EVSettings.arrivalPercent : EVSettings.minAtChargerPercent
        CarPlayBatteryChip.shared.show(label: last ? "Ziel" : "Stopp", percent: arrival, low: arrival < limit, live: live != nil)
    }

    func check() async {
        updateForecast()
        guard EVSettings.enabled, let vehicle = EVSettings.vehicle,
              let soc = AppModel.shared.vehicle.liveSoc, let status = AppModel.shared.vehicle.status,
              status.age < 4 * 60,                                              // nur mit frischem Live-Wert
              let routes = navigationProvider.mapboxNavigation.tripSession().currentNavigationRoutes,
              let progress = navigationProvider.mapboxNavigation.navigation().currentRouteProgress?.routeProgress
        else { return }
        let route = routes.mainRoute.route
        let traveled = progress.distanceTraveled
        var settings = EVSettings.plannerSettings
        settings.availability = await ChargeStatusService.shared.availability(along: route)
        let result = await Task.detached(priority: .utility) {
            let rest = ChargePlanner.profile(of: route, vehicle: vehicle, temperature: settings.temperature,
                                             factors: settings.factors).suffix(from: traveled)
            return ChargePlanner.plan(profile: rest, vehicle: vehicle, startPercent: soc, settings: settings,
                                      sites: ChargeSites.all)
        }.value

        // Zwischenziele der laufenden Route, die noch vor mir liegen (bereits übernommene Ladestopps)
        let legIndex = progress.legIndex
        let upcoming = route.legs.enumerated().dropLast()
            .filter { $0.offset >= legIndex }
            .compactMap { $0.element.destination?.coordinate }

        let message: (title: String, subtitle: String, plan: ChargePlanner.Plan?)?
        switch result {
        case .failure(.unreachable(let km)):
            message = ("Akku reicht nicht bis zum Ziel", "Reichweite ca. \(Int(km)) km – Ladesäulen unter „Mehr“", nil)
        case .failure(.noVehicle):
            message = nil
        case .success(let plan):
            let planned = plan.stops.map(\.site.coordinate)
            let matches = planned.count == upcoming.count
                && zip(planned, upcoming).allSatisfy { $0.distance(to: $1) < 600 }
            if matches || (plan.direct && upcoming.isEmpty) {
                message = nil
            } else if plan.direct {
                message = ("Ladestopp nicht mehr nötig", "Ankunft mit \(Int(plan.arrivalPercent.rounded())) % auch ohne Laden", plan)
            } else {
                let first = plan.stops[0]
                message = ("Neuer Ladeplan: \(plan.summary)",
                           "Nächster Stopp: \(first.site.title) in \(Int(first.distanceFromStart / 1000)) km", plan)
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

    private func present(_ title: String, _ subtitle: String, plan: ChargePlanner.Plan?) {
        let carPlay = CarPlayController.shared
        guard carPlay.isConnected, let template = carPlay.alertTemplate, template.currentNavigationAlert == nil else {
            AppModel.shared.show("\(title) – \(subtitle)", isError: plan == nil)
            return
        }
        let primary: CPAlertAction
        if let plan {
            primary = CPAlertAction(title: "Übernehmen", style: .default) { _ in
                Task { @MainActor in await CarPlayController.adoptChargePlan(plan) }
            }
        } else {
            primary = CPAlertAction(title: "Ladesäulen", style: .default) { _ in
                Task { @MainActor in carPlay.showChargingStops() }
            }
        }
        let alert = CPNavigationAlert(titleVariants: [title], subtitleVariants: [subtitle],
                                      image: UIImage(systemName: "bolt.car.fill"),
                                      primaryAction: primary,
                                      secondaryAction: CPAlertAction(title: "Nein", style: .cancel) { _ in },
                                      duration: 20)
        if !CarPlayUI.shared.alert(alert) { AppModel.shared.show("\(title) – \(subtitle)", isError: plan == nil) }
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
