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

    func start() {
        stop()
        guard EVSettings.enabled, EVSettings.vehicle != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in await ChargeMonitor.shared.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSignature = ""
    }

    func check() async {
        guard EVSettings.enabled, let vehicle = EVSettings.vehicle,
              let soc = AppModel.shared.vehicle.liveSoc, let status = AppModel.shared.vehicle.status,
              status.age < 4 * 60,                                              // nur mit frischem Live-Wert
              let routes = navigationProvider.mapboxNavigation.tripSession().currentNavigationRoutes,
              let progress = navigationProvider.mapboxNavigation.navigation().currentRouteProgress?.routeProgress
        else { return }
        let route = routes.mainRoute.route
        let traveled = progress.distanceTraveled
        let settings = EVSettings.plannerSettings
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
        template.present(navigationAlert: alert, animated: true)
    }
}
