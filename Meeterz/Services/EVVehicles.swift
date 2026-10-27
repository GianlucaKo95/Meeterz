import Foundation

/// Fahrzeugprofil für E-Autos: Batterie, Verbrauch, Ladeleistung und Ladekurve.
/// Katalog aus Open EV Data (https://github.com/KilowattApp/open-ev-data, MIT mit Namensnennung),
/// erzeugt mit tools/build_ev_vehicles.py; „Andere“ = eigene Werte.
struct EVVehicle: Codable, Identifiable, Hashable {
    let id: String
    let brand: String
    let model: String
    let variant: String
    let year: Int?
    /// Nutzbare Batterie in kWh
    let battery: Double
    /// Durchschnittsverbrauch in kWh/100 km
    let consumption: Double
    /// Maximale DC-Ladeleistung in kW
    let dcMax: Double?
    /// Ladekurve: [Prozent, kW]
    let curve: [[Double]]
    let ports: [String]
    /// Ladekurve automatisch geschätzt (kein gepflegter Eintrag)
    let estimated: Bool

    static let customId = "custom"

    var isCustom: Bool { id == Self.customId }

    /// „MG5 EV Long Range“
    var name: String { [model, variant].filter { !$0.isEmpty }.joined(separator: " ") }
    /// „MG MG5 EV Long Range (2022)“
    var fullName: String { isCustom ? String(localized: "Eigenes Fahrzeug") : "\(brand) \(name)" + (year.map { " (\($0))" } ?? "") }

    /// „57 kWh · 17,5 kWh/100 km · 80 kW DC“
    var specs: String {
        var parts = [String(localized: "\(Self.number(battery)) kWh"), String(localized: "\(Self.number(consumption)) kWh/100 km")]
        if let dcMax { parts.append(String(localized: "\(Self.number(dcMax)) kW DC")) }
        return parts.joined(separator: " · ")
    }

    /// Reichweite bei 100 % in km aus Batterie und Durchschnittsverbrauch
    var rangeKm: Double { consumption > 0 ? battery / consumption * 100 : 0 }

    /// Ladeleistung (kW) bei einem Akkustand, linear zwischen den Punkten der Ladekurve
    func chargingPower(atPercent p: Double) -> Double {
        let points = curve.filter { $0.count == 2 }.sorted { $0[0] < $1[0] }
        guard let first = points.first else { return dcMax ?? 50 }
        if p <= first[0] { return first[1] }
        for (a, b) in zip(points, points.dropFirst()) where p <= b[0] {
            let t = (p - a[0]) / max(b[0] - a[0], 0.001)
            return a[1] + (b[1] - a[1]) * t
        }
        return points.last![1]
    }

    static func custom(battery: Double, consumption: Double, dcMax: Double) -> EVVehicle {
        EVVehicle(id: customId, brand: String(localized: "Andere"), model: String(localized: "Eigenes Fahrzeug"), variant: "", year: nil,
                  battery: battery, consumption: consumption, dcMax: dcMax,
                  // Typische Form: volle Leistung bis 50 %, dann abfallend
                  curve: [[0, dcMax], [50, dcMax], [80, dcMax * 0.55], [100, dcMax * 0.15]],
                  ports: ["ccs"], estimated: true)
    }

    private static func number(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : v.formatted(.number.precision(.fractionLength(1)))
    }
}

/// Fahrzeugkatalog (gebündelt in der App)
enum EVCatalog {
    struct File: Decodable { let vehicles: [EVVehicle] }

    static let all: [EVVehicle] = {
        guard let url = Bundle.main.url(forResource: "ev-vehicles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.vehicles
    }()

    /// Nach Marke gruppiert, alphabetisch
    static var byBrand: [(brand: String, vehicles: [EVVehicle])] {
        Dictionary(grouping: all, by: \.brand)
            .map { ($0.key, $0.value) }
            .sorted { $0.brand.localizedCaseInsensitiveCompare($1.brand) == .orderedAscending }
    }

    static let attribution = String(localized: "Fahrzeugdaten: Open EV Data (github.com/KilowattApp/open-ev-data)")
}
