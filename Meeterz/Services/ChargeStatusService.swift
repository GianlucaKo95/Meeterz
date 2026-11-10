import Foundation
import CoreLocation
import Compression
import MapboxDirections
import Supabase

/// Live-Belegung der Ladesäulen: Schweiz (Bundesamt für Energie, alle ~1 Min. aktualisiert) direkt,
/// Deutschland über die Mobilithek (AFIR-Daten der Betreiber, von unserem Server gesammelt – RPC charge_availability).
@MainActor
final class ChargeStatusService {
    static let shared = ChargeStatusService()

    private static let swissURL = URL(string: "https://data.geo.admin.ch/ch.bfe.ladestellen-elektromobilitaet/status/oicp/ch.bfe.ladestellen-elektromobilitaet.json")!
    private var swiss: [String: String] = [:]   // EvseID → Available / Occupied / OutOfService …
    private var swissLoaded = Date.distantPast
    private var loading: Task<Void, Never>?

    /// Belegung für alle Standorte mit Ladepunkt-IDs entlang der Route (lädt die Daten bei Bedarf, max. alle 3 Min.)
    func availability(along route: Route) async -> [ChargeSite: ChargeAvailability] {
        guard let coords = route.shape?.coordinates, !coords.isEmpty else { return [:] }
        var result = await germany(along: coords)
        // Schweiz nur laden, wenn die Route sie berührt
        let inSwitzerland = coords.contains { $0.latitude > 45.8 && $0.latitude < 47.9 && $0.longitude > 5.9 && $0.longitude < 10.5 }
        guard inSwitzerland else { return result }
        await refreshSwiss()
        for site in ChargeSites.all where !site.evseIds.isEmpty {
            var a = ChargeAvailability()
            for id in site.evseIds {
                switch swiss[id]?.lowercased() {
                case "available": a.free += 1
                case "occupied", "reserved": a.occupied += 1
                case "outofservice", "out of service": a.outOfService += 1
                default: break   // unbekannt
                }
            }
            if a.total > 0 { result[site] = a }
        }
        return result
    }

    /// Mobilithek-Standorte im Korridor der Route, je dem nächsten eigenen Standort (bis 150 m) zugeordnet
    private func germany(along coords: [CLLocationCoordinate2D]) async -> [ChargeSite: ChargeAvailability] {
        struct Row: Decodable {
            let lat: Double, lng: Double
            let free: Int, occupied: Int, out_of_service: Int
            let price_kwh: Double?
        }
        struct Params: Encodable { let lats: [Double]; let lngs: [Double] }
        // Punkte alle ~5 km (höchstens 400)
        var samples: [CLLocationCoordinate2D] = []
        for c in coords where samples.last.map({ $0.distance(to: c) >= 5_000 }) ?? true { samples.append(c) }
        if let last = coords.last { samples.append(last) }
        let step = max(1, samples.count / 400)
        let picked = stride(from: 0, to: samples.count, by: step).map { samples[$0] }
        let rows: [Row]
        do {
            rows = try await Backend.client.rpc("charge_availability", params: Params(
                lats: picked.map(\.latitude), lngs: picked.map(\.longitude))).execute().value
        } catch {
            Diag.log("Ladesäulen-Belegung DE: \(error.localizedDescription)")
            return [:]
        }
        guard !rows.isEmpty else { return [:] }
        // Eigene Standorte im selben Bereich, dann je Meldung den nächsten
        let lats = rows.map(\.lat), lngs = rows.map(\.lng)
        let minLat = lats.min()! - 0.01, maxLat = lats.max()! + 0.01, minLng = lngs.min()! - 0.015, maxLng = lngs.max()! + 0.015
        let nearby = ChargeSites.all.filter { $0.coordinate.latitude > minLat && $0.coordinate.latitude < maxLat
            && $0.coordinate.longitude > minLng && $0.coordinate.longitude < maxLng }
        var result: [ChargeSite: ChargeAvailability] = [:]
        for row in rows {
            let here = CLLocationCoordinate2D(latitude: row.lat, longitude: row.lng)
            guard let site = nearby.min(by: { $0.coordinate.distance(to: here) < $1.coordinate.distance(to: here) }),
                  site.coordinate.distance(to: here) < 150 else { continue }
            var a = result[site] ?? ChargeAvailability()
            a.free += row.free; a.occupied += row.occupied; a.outOfService += row.out_of_service
            if let p = row.price_kwh { a.priceKwh = min(a.priceKwh ?? p, p) }
            result[site] = a
        }
        Diag.log("Ladesäulen-Belegung DE: \(rows.count) Standorte gemeldet, \(result.count) zugeordnet")
        return result
    }

    private func refreshSwiss() async {
        if Date().timeIntervalSince(swissLoaded) < 180 { return }
        if let loading { await loading.value; return }
        let task = Task { @MainActor in
            defer { self.loading = nil }
            guard let (data, _) = try? await URLSession.shared.data(from: Self.swissURL) else {
                Diag.log("Ladesäulen-Belegung CH: nicht erreichbar"); return
            }
            let body = Self.gunzip(data) ?? data
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
            var map: [String: String] = [:]
            for block in json["EVSEStatuses"] as? [[String: Any]] ?? [] {
                for rec in block["EVSEStatusRecord"] as? [[String: Any]] ?? [] {
                    if let id = rec["EvseID"] as? String, let status = rec["EVSEStatus"] as? String { map[id] = status }
                }
            }
            if !map.isEmpty {
                self.swiss = map
                self.swissLoaded = Date()
                Diag.log("Ladesäulen-Belegung CH: \(map.count) Ladepunkte")
            }
        }
        loading = task
        await task.value
    }

    /// gzip entpacken (falls der Server die Datei komprimiert ausliefert, ohne Content-Encoding)
    private static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else { return nil }
        var start = 10
        let flags = data[3]
        if flags & 0x04 != 0 { start += 2 + Int(data[start]) + Int(data[start + 1]) << 8 }
        if flags & 0x08 != 0 { while start < data.count, data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x10 != 0 { while start < data.count, data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x02 != 0 { start += 2 }
        let deflated = data.subdata(in: start..<(data.count - 8))
        let capacity = max(data.count * 12, 1 << 20)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            deflated.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, deflated.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}
