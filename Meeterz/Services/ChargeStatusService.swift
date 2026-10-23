import Foundation
import CoreLocation
import Compression
import MapboxDirections

/// Live-Belegung der Ladesäulen. Bisher offen verfügbar: Schweiz (Bundesamt für Energie, alle ~1 Min. aktualisiert).
/// Weitere Länder (z. B. Deutschland über die Mobilithek) kommen hier dazu, sobald ein Zugang besteht.
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
        // Nur laden, wenn die Route die Schweiz berührt
        let inSwitzerland = coords.contains { $0.latitude > 45.8 && $0.latitude < 47.9 && $0.longitude > 5.9 && $0.longitude < 10.5 }
        guard inSwitzerland else { return [:] }
        await refreshSwiss()
        var result: [ChargeSite: ChargeAvailability] = [:]
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
