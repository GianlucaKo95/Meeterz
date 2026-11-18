import Foundation
import CoreLocation
import Observation
import Supabase
import Turf
import MapboxNavigationCore

// MARK: - Spritpreise

/// Spritpreise der Markttransparenzstelle (über Tankerkönig, CC BY 4.0) – Edge Function „fuel-prices“,
/// je Ort 5 Minuten zwischengespeichert. Ohne hinterlegten Schlüssel kommt nichts (dann bleibt die Anzeige leer).
@MainActor
enum FuelPrices {
    struct Price: Decodable, Equatable {
        let e5: Double?, e10: Double?, diesel: Double?
        let open: Bool?
        let brand: String?

        var text: String {
            [("E5", e5), ("E10", e10), ("Diesel", diesel)].compactMap { name, v in
                v.map { "\(name) \($0.formatted(.number.precision(.fractionLength(3))))" }
            }.joined(separator: " · ")
        }
    }

    static let attribution = "Preise: MTS-K via Tankerkönig"

    private static var cache: [String: (at: Date, price: Price?)] = [:]

    private static func key(_ c: CLLocationCoordinate2D) -> String { String(format: "%.4f,%.4f", c.latitude, c.longitude) }

    /// Ist der Ort eine Tankstelle? (Mapbox-Kategorie bzw. Name)
    static func isGasStation(category: String?, name: String) -> Bool {
        let s = ((category ?? "") + " " + name).lowercased()
        return ["tankstelle", "gas station", "fuel", "gas_station", "aral", "shell", "esso", "jet ", "total"].contains { s.contains($0) }
    }

    /// Preise je Ort (gleiche Reihenfolge; nil = nicht bekannt)
    static func prices(for coords: [CLLocationCoordinate2D]) async -> [Price?] {
        let missing = coords.filter { c in cache[key(c)].map { Date().timeIntervalSince($0.at) > 300 } ?? true }
        if !missing.isEmpty {
            struct Point: Encodable { let lat: Double; let lng: Double }
            struct Body: Encodable { let points: [Point] }
            struct Response: Decodable { let prices: [Price?] }
            let chunk = Array(missing.prefix(10))
            if let r: Response = try? await Backend.client.functions.invoke(
                "fuel-prices", options: FunctionInvokeOptions(body: Body(points: chunk.map { Point(lat: $0.latitude, lng: $0.longitude) }))) {
                for (c, p) in zip(chunk, r.prices) { cache[key(c)] = (Date(), p) }
            }
        }
        return coords.map { cache[key($0)]?.price ?? nil }
    }
}

// MARK: - Gefahren melden

/// Gefahren, die Meeterz-Fahrer melden (wie bei Google Maps/Waze): eine Stunde gültig, angesagt, wenn sie auf
/// der eigenen Route voraus liegen. Geladen wird höchstens alle 5 Minuten (nur während der Navigation).
@MainActor
final class HazardStore {
    static let shared = HazardStore()

    enum Kind: String, CaseIterable, Identifiable {
        case accident, jam, object, breakdown, ice
        var id: String { rawValue }
        var title: String {
            switch self {
            case .accident: String(localized: "Unfall")
            case .jam: String(localized: "Stau")
            case .object: String(localized: "Gegenstand auf der Fahrbahn")
            case .breakdown: String(localized: "Pannenfahrzeug")
            case .ice: String(localized: "Glätte")
            }
        }
        var symbol: String {
            switch self {
            case .accident: "car.side.rear.and.collision.and.car.side.front"
            case .jam: "car.2.fill"
            case .object: "exclamationmark.triangle.fill"
            case .breakdown: "car.side.front.open.fill"
            case .ice: "snowflake"
            }
        }
    }

    struct Hazard: Decodable, Identifiable {
        let id: UUID
        let kind: String
        let lat: Double, lng: Double
        let heading: Double?
        let by_friend: Bool
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
        var type: Kind? { Kind(rawValue: kind) }
    }

    private(set) var items: [Hazard] = []
    private var loadedAt = Date.distantPast
    private var loading = false
    private var announced: Set<UUID> = []

    func reset() { items = []; loadedAt = .distantPast; announced = [] }

    /// Melden an der aktuellen Position (mit Fahrtrichtung, damit die Gegenfahrbahn nicht gewarnt wird)
    func report(_ kind: Kind) async {
        guard let loc = AppModel.shared.location.lastLocation else {
            AppModel.shared.show(String(localized: "Standort unbekannt"))
            return
        }
        struct Params: Encodable { let kind: String; let lat: Double; let lng: Double; let heading: Double? }
        do {
            try await Backend.client.rpc("report_hazard", params: Params(
                kind: kind.rawValue, lat: loc.coordinate.latitude, lng: loc.coordinate.longitude,
                heading: loc.course >= 0 ? loc.course : nil)).execute()
            Diag.log("Gefahr gemeldet: \(kind.rawValue)")
            AppModel.shared.show(String(localized: "Danke! \(kind.title) gemeldet."), isError: false)
        } catch {
            Diag.log("Gefahr melden fehlgeschlagen: \(error.localizedDescription)")
            AppModel.shared.show(String(localized: "Meldung nicht möglich – höchstens eine pro Minute."))
        }
    }

    /// Während der Navigation (je Fortschritt): Meldungen auf der Route voraus ansagen, einmal je Meldung
    func check(_ progress: RouteProgress) {
        guard let shape = progress.route.shape, shape.coordinates.count > 1 else { return }
        if Date().timeIntervalSince(loadedAt) > 300, !loading { Task { await load(shape.coordinates) } }
        let coords = shape.coordinates
        for h in items where !announced.contains(h.id) {
            guard let type = h.type, let snap = shape.closestCoordinate(to: h.coordinate),
                  snap.coordinate.distance(to: h.coordinate) < 40 else { continue }
            // Strecke vom Routenanfang bis zur Meldung
            var along = coords[snap.index].distance(to: snap.coordinate)
            for i in 0..<snap.index { along += coords[i].distance(to: coords[i + 1]) }
            let ahead = along - progress.distanceTraveled
            guard ahead > 150, ahead < 2_000 else {
                if ahead <= 150, ahead > -500 { announced.insert(h.id) }
                continue
            }
            // Gegenrichtung? Fahrtrichtung der Meldung mit der Richtung der Route an der Stelle vergleichen
            if let heading = h.heading, snap.index + 1 < coords.count {
                let bearing = coords[snap.index].direction(to: coords[snap.index + 1])
                let diff = abs((bearing - heading + 540).truncatingRemainder(dividingBy: 360) - 180)
                if diff > 60 { announced.insert(h.id); continue }
            }
            announced.insert(h.id)
            let source = h.by_friend ? String(localized: "von einem Freund gemeldet") : String(localized: "von Meeterz-Fahrern gemeldet")
            IncidentWatcher.shared.announceReported(title: type.title, subtitle: source, symbol: type.symbol, distance: ahead)
            return
        }
    }

    private func load(_ coords: [CLLocationCoordinate2D]) async {
        loading = true
        defer { loading = false }
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        struct Params: Encodable { let min_lat: Double; let min_lng: Double; let max_lat: Double; let max_lng: Double }
        let pad = 0.01
        guard let rows: [Hazard] = try? await Backend.client.rpc("hazards_in", params: Params(
            min_lat: lats.min()! - pad, min_lng: lngs.min()! - pad, max_lat: lats.max()! + pad, max_lng: lngs.max()! + pad))
            .execute().value else { return }
        items = rows
        loadedAt = Date()
    }
}

// MARK: - Gespeicherte Listen

/// Eigene Ortslisten („Lieblingscafés“), auf Wunsch mit Freunden geteilt (die lesen nur). Geladen nur beim Öffnen.
@MainActor @Observable
final class PlaceListsStore {
    struct Item: Codable, Identifiable, Hashable {
        var id: UUID
        var list_id: UUID
        var name: String
        var address: String?
        var lat: Double, lng: Double
        var place: Place { Place(id: "list-\(id)", name: name, address: address, coordinate: .init(latitude: lat, longitude: lng)) }
    }

    struct PlaceList: Codable, Identifiable, Hashable {
        var id: UUID
        var owner: UUID
        var name: String
        var shared: Bool
        var place_list_items: [Item]?
        var items: [Item] { place_list_items ?? [] }
    }

    private(set) var lists: [PlaceList] = []
    private(set) var loaded = false
    private var client: SupabaseClient { Backend.client }
    var me: UUID? { client.auth.currentUser?.id }
    var own: [PlaceList] { lists.filter { $0.owner == me } }
    var fromFriends: [PlaceList] { lists.filter { $0.owner != me } }

    func refresh() async {
        guard let rows: [PlaceList] = try? await client.from("place_lists")
            .select("id, owner, name, shared, place_list_items(id, list_id, name, address, lat, lng)")
            .order("created_at").execute().value else { return }
        lists = rows
        loaded = true
    }

    func create(_ name: String, shared: Bool) async -> PlaceList? {
        struct Row: Encodable { let name: String; let shared: Bool }
        let list: PlaceList? = try? await client.from("place_lists").insert(Row(name: name, shared: shared))
            .select("id, owner, name, shared").single().execute().value
        if let list { lists.append(list) }
        return list
    }

    func add(_ place: Place, to list: PlaceList) async {
        struct Row: Encodable { let list_id: UUID; let name: String; let address: String?; let lat: Double; let lng: Double }
        do {
            try await client.from("place_list_items").insert(Row(list_id: list.id, name: place.name, address: place.address,
                                                                lat: place.coordinate.latitude, lng: place.coordinate.longitude)).execute()
            AppModel.shared.show(String(localized: "In „\(list.name)“ gespeichert."), isError: false)
            await refresh()
        } catch {
            AppModel.shared.show(String(localized: "Speichern fehlgeschlagen."))
        }
    }

    func remove(_ item: Item) async {
        _ = try? await client.from("place_list_items").delete().eq("id", value: item.id).execute()
        await refresh()
    }

    func delete(_ list: PlaceList) async {
        _ = try? await client.from("place_lists").delete().eq("id", value: list.id).execute()
        lists.removeAll { $0.id == list.id }
    }

    func setShared(_ list: PlaceList, _ shared: Bool) async {
        _ = try? await client.from("place_lists").update(["shared": shared]).eq("id", value: list.id).execute()
        await refresh()
    }
}
