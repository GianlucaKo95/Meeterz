import Foundation

/// Lernt den echten Verbrauch aus den Live-Fahrzeugdaten: zwischen zwei Meldungen Kilometerstand- und
/// Akkustand-Differenz, eingeordnet nach Tempobereich. Ergebnis ist ein Korrekturfaktor gegenüber dem
/// Verbrauchsmodell (Fahrzeugprofil × Tempo × Temperatur), den die Ladeplanung anwendet.
enum ConsumptionLearner {
    static let bandNames = [String(localized: "Stadt"), String(localized: "Landstraße"), String(localized: "Autobahn")]
    /// Ab so vielen Kilometern in einem Bereich gilt der gelernte Wert
    static let minKm: Double = 25

    static func band(kmh: Double) -> Int { kmh < 60 ? 0 : (kmh <= 100 ? 1 : 2) }

    struct Bucket: Codable {
        var km: Double = 0
        /// Gemessene Energie (kWh) und vom Modell erwartete Energie für dieselben Kilometer
        var measured: Double = 0
        var modeled: Double = 0
        var factor: Double? { km >= ConsumptionLearner.minKm && modeled > 0 ? min(1.5, max(0.65, measured / modeled)) : nil }
        /// kWh/100 km gemessen
        var per100: Double? { km > 0 ? measured / km * 100 : nil }
    }

    private static func key(_ vehicle: EVVehicle) -> String { "ev.learned.\(vehicle.id)" }

    static func buckets(for vehicle: EVVehicle) -> [Bucket] {
        guard let data = UserDefaults.standard.data(forKey: key(vehicle)),
              let b = try? JSONDecoder().decode([Bucket].self, from: data), b.count == 3 else { return Array(repeating: Bucket(), count: 3) }
        return b
    }

    /// Korrekturfaktoren je Bereich; fehlt ein Bereich, gilt der Mittelwert der gelernten, sonst 1
    static func factors(for vehicle: EVVehicle) -> [Double] {
        let b = buckets(for: vehicle)
        let known = b.compactMap(\.factor)
        let fallback = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
        return b.map { $0.factor ?? fallback }
    }

    /// Zwei aufeinanderfolgende Meldungen auswerten (nur während der Fahrt, nicht beim Laden)
    @MainActor static func record(previous a: VehicleStore.Status, current b: VehicleStore.Status) {
        guard EVSettings.enabled, let vehicle = EVSettings.vehicle,
              let socA = a.soc, let socB = b.soc, let kmA = a.odometerKm, let kmB = b.odometerKm,
              a.charging != true, b.charging != true else { return }
        let km = kmB - kmA
        let seconds = b.measuredAt.timeIntervalSince(a.measuredAt)
        // Plausibel: 0,3–30 km in höchstens 15 Minuten, Akku nicht gestiegen (sonst geladen)
        guard km >= 0.3, km <= 30, seconds > 20, seconds < 15 * 60, socB <= socA + 0.5 else { return }
        let kmh = km / (seconds / 3600)
        guard kmh > 5, kmh < 220 else { return }
        let measured = (socA - socB) / 100 * vehicle.battery
        let temperature = b.extTemp ?? a.extTemp
        let modeled = ChargePlanner.consumption(kmh: kmh, base: vehicle.consumption, temperature: temperature) * km
        var all = buckets(for: vehicle)
        let i = band(kmh: kmh)
        all[i].km += km
        all[i].measured += measured
        all[i].modeled += modeled
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key(vehicle)) }
    }

    static func reset(for vehicle: EVVehicle) {
        UserDefaults.standard.removeObject(forKey: key(vehicle))
    }
}
