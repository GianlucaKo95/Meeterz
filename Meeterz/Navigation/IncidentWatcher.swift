import Foundation
import UIKit
import CarPlay
import MapboxDirections
import MapboxNavigationCore

/// Unfälle, Sperrungen und schwere Staus voraus melden (wie Google Maps), einmal je Ereignis.
///
/// Die Daten liefert Mapbox mit der Route (`RouteProgress.upcomingRouteAlerts`, Entfernung vom aktuellen Standort);
/// die App hat sie bisher nur für die Farbe der Route genutzt. Gemeldet wird nur, was den Fahrer wirklich betrifft:
/// Unfall, Sperrung, liegengebliebenes Fahrzeug, Gefahr, schwerer Stau, Baustelle mit gesperrten Fahrstreifen.
@MainActor
final class IncidentWatcher {
    static let shared = IncidentWatcher()

    private var announced: Set<String> = []

    func reset() { announced = [] }

    func check(_ progress: RouteProgress) {
        for alert in progress.upcomingRouteAlerts {
            guard case .incident(let incident?) = alert.roadObject.kind,
                  !announced.contains(incident.identifier),
                  let message = Self.message(incident, length: alert.roadObject.length) else { continue }
            let distance = alert.distanceToStart
            // Sperrungen früh (bis 15 km), sonst bis 6 km; unter 300 m ist es zu spät für einen Hinweis
            let horizon: Double = message.closure ? 15_000 : 6_000
            guard distance > 300, distance < horizon else {
                if distance <= 300 { announced.insert(incident.identifier) }
                continue
            }
            let title = "\(message.title) in \(Format.distance(distance))"
            if present(title: title, subtitle: message.subtitle, symbol: message.symbol) {
                announced.insert(incident.identifier)
                Diag.log("Verkehrsmeldung: \(title)\(message.subtitle.map { " – \($0)" } ?? "")")
                MeeterzSpeechSynthesizer.shared.announce("Achtung, \(message.title) in \(Self.spoken(distance)).")
            }
            return   // höchstens eine Meldung auf einmal
        }
    }

    /// Hinweis in CarPlay (über die Warteschlange), ohne CarPlay auf dem iPhone. Gibt zurück, ob er erschien.
    private func present(title: String, subtitle: String?, symbol: String) -> Bool {
        let carPlay = CarPlayController.shared
        guard carPlay.isConnected else {
            AppModel.shared.show([title, subtitle].compactMap { $0 }.joined(separator: " – "), isError: false)
            return true
        }
        let ok = CPAlertAction(title: "OK", style: .cancel) { _ in }
        let alert = CPNavigationAlert(titleVariants: [title], subtitleVariants: subtitle.map { [$0] },
                                      image: UIImage(systemName: symbol), primaryAction: ok, secondaryAction: nil,
                                      duration: 10)
        return CarPlayUI.shared.alert(alert)
    }

    struct Message {
        let title: String
        let subtitle: String?
        let symbol: String
        let closure: Bool
    }

    /// Was melden – und wie? nil = nicht melden
    static func message(_ incident: Incident, length: Double?) -> Message? {
        let road = incident.affectedRoadNames?.first
        let lanes = incident.numberOfBlockedLanes ?? 0
        let lengthText = length.flatMap { $0 > 300 ? "\(Format.distance($0)) lang" : nil }
        let severe = incident.impact == .major || incident.impact == .critical
        if incident.roadIsClosed == true || incident.kind == .roadClosure {
            return Message(title: "Sperrung", subtitle: road.map { "\($0) gesperrt" } ?? "Straße gesperrt",
                           symbol: "xmark.octagon.fill", closure: true)
        }
        switch incident.kind {
        case .accident:
            let detail = lanes > 0 ? "\(lanes) Fahrstreifen blockiert" : road
            return Message(title: "Unfall", subtitle: detail, symbol: "car.side.rear.and.collision.and.car.side.front", closure: false)
        case .disabledVehicle:
            return Message(title: "Liegengebliebenes Fahrzeug", subtitle: road, symbol: "exclamationmark.triangle.fill", closure: false)
        case .roadHazard:
            return Message(title: "Gefahr auf der Fahrbahn", subtitle: road, symbol: "exclamationmark.triangle.fill", closure: false)
        case .congestion where severe:
            return Message(title: "Stau", subtitle: [lengthText, road].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                           symbol: "car.2.fill", closure: false)
        case .construction where lanes > 0 || severe:
            return Message(title: "Baustelle", subtitle: lanes > 0 ? "\(lanes) Fahrstreifen gesperrt" : road,
                           symbol: "cone.fill", closure: false)
        case .weather where severe:
            return Message(title: "Wettergefahr", subtitle: road, symbol: "cloud.bolt.rain.fill", closure: false)
        default:
            return nil
        }
    }

    /// „3 Kilometern“, „800 Metern“ – für die Ansage
    nonisolated static func spoken(_ meters: Double) -> String {
        if meters >= 1_000 {
            let km = (meters / 1_000).rounded()
            return km == 1 ? "einem Kilometer" : "\(Int(km)) Kilometern"
        }
        return "\(Int((meters / 100).rounded()) * 100) Metern"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
