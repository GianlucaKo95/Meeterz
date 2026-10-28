import Foundation
import Observation
import Supabase

/// Live-Fahrzeugdaten (E-Auto) aus Supabase: geschrieben von der Edge-Function vehicle-telemetry,
/// gespeist z. B. vom Home-Assistant-Add-on „MG to ABRP Bridge“.
@MainActor @Observable
final class VehicleStore {
    struct Status: Decodable, Equatable {
        let soc: Double?
        let rangeKm: Double?
        let charging: Bool?
        let powerKw: Double?
        let extTemp: Double?
        let odometerKm: Double?
        let speedKmh: Double?
        let parked: Bool?
        let lat: Double?
        let lng: Double?
        let reportedAt: Date?
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case soc, charging, parked, lat, lng
            case rangeKm = "range_km"
            case powerKw = "power_kw"
            case extTemp = "ext_temp"
            case odometerKm = "odometer_km"
            case speedKmh = "speed_kmh"
            case reportedAt = "reported_at"
            case updatedAt = "updated_at"
        }

        /// Wann im Auto gemessen (sonst: wann angekommen)
        var measuredAt: Date { reportedAt ?? updatedAt }
        /// Alter der Messung
        var age: TimeInterval { Date().timeIntervalSince(measuredAt) }
    }

    private(set) var status: Status?
    /// Gerätetoken fürs Add-on (nur vorhanden, wenn verbunden)
    private(set) var token: String?
    private(set) var loaded = false

    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var listener: Task<Void, Never>?
    private var client: SupabaseClient { Backend.client }

    /// Live-Akkustand, wenn er frisch genug für die Planung ist (beim Fahren alle ~30 s, geparkt seltener)
    var liveSoc: Double? {
        guard let status, let soc = status.soc, status.age < 6 * 3600 else { return nil }
        return soc
    }

    /// Adresse, die im Add-on als OsmAnd-Server eingetragen wird
    static var telemetryURL: String {
        AppConfig.value("SUPABASE_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/functions/v1/vehicle-telemetry"
    }

    func startListening(userId: UUID) async {
        guard channel == nil else { return }
        let ch = client.channel("vehicle-\(userId.uuidString.lowercased())")
        let changes = ch.postgresChange(AnyAction.self, schema: "public", table: "vehicle_status",
                                        filter: .eq("user_id", value: userId))
        channel = ch
        try? await ch.subscribeWithError()
        listener = Task { [weak self] in
            for await _ in changes { await self?.refresh() }
        }
        await refresh()
    }

    func stopListening() async {
        listener?.cancel()
        listener = nil
        if let ch = channel { await client.removeChannel(ch) }
        channel = nil
        status = nil
        token = nil
        loaded = false
    }

    func refresh() async {
        guard let uid = AppModel.shared.auth.profile?.id else { return }
        struct Link: Decodable { let token: String }
        let links: [Link] = (try? await client.from("vehicle_links").select("token").eq("user_id", value: uid).execute().value) ?? []
        token = links.first?.token
        let rows: [Status] = (try? await client.from("vehicle_status").select().eq("user_id", value: uid).execute().value) ?? []
        let new = rows.first
        // Nur bei geändertem Akkustand oder Ladezustand – sonst alle 40 s eine Zeile, die das Log füllte
        if let soc = new?.soc, soc.rounded() != status?.soc?.rounded() || new?.charging != status?.charging {
            Diag.log("Fahrzeug: \(Int(soc)) %\(new?.charging == true ? ", lädt" : ""), Messung \(Int(new?.age ?? 0)) s alt")
        }
        if let old = status, let new, new.measuredAt > old.measuredAt {
            ConsumptionLearner.record(previous: old, current: new)
        }
        status = new
        loaded = true
        ChargingSession.shared.update(new)
        ParkingDetector.shared.vehicleUpdate(new)
        if AppModel.shared.navigation.isNavigating { ChargeMonitor.shared.updateForecast() }
    }

    /// Neues Gerätetoken anlegen (ein altes wird ungültig)
    @discardableResult
    func connect() async -> String? {
        do {
            let t: String = try await client.rpc("create_vehicle_link").execute().value
            token = t
            return t
        } catch {
            AppModel.shared.show(String(localized: "Verbinden fehlgeschlagen: \(error.localizedDescription)"))
            return nil
        }
    }

    func disconnect() async {
        _ = try? await client.rpc("remove_vehicle_link").execute()
        token = nil
        status = nil
    }
}
