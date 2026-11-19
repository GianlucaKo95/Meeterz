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

    /// Meldung an den Konvoi (Live-Kanal, Ereignis „hazard“). Feldnamen nur gemeinsam mit Android ändern.
    struct Shared: Codable {
        let id: UUID
        let from: UUID
        let kind: String
        let lat: Double, lng: Double
        let heading: Double?
    }

    private(set) var items: [Hazard] = []
    private var loadedAt = Date.distantPast
    private var loading = false
    private var announced: Set<UUID> = []
    /// Letzter Fortschritt der Navigation – um eine Konvoi-Meldung sofort einzuordnen
    private var lastProgress: RouteProgress?

    func reset() { items = []; loadedAt = .distantPast; announced = []; lastProgress = nil }

    /// Melden an der aktuellen Position (mit Fahrtrichtung, damit die Gegenfahrbahn nicht gewarnt wird)
    func report(_ kind: Kind) async {
        guard let loc = AppModel.shared.location.lastLocation else {
            AppModel.shared.show(String(localized: "Standort unbekannt"))
            return
        }
        struct Params: Encodable { let kind: String; let lat: Double; let lng: Double; let heading: Double? }
        do {
            let heading = loc.course >= 0 ? loc.course : nil
            let id: UUID = try await Backend.client.rpc("report_hazard", params: Params(
                kind: kind.rawValue, lat: loc.coordinate.latitude, lng: loc.coordinate.longitude,
                heading: heading)).execute().value
            Diag.log("Gefahr gemeldet: \(kind.rawValue)")
            // Im Konvoi sofort an die anderen – wer noch daran vorbei muss, wird gleich gewarnt (nicht erst beim
            // nächsten Laden in bis zu 5 Min.)
            if let me = Backend.client.auth.currentUser?.id, !ConvoyTracker.shared.members().isEmpty {
                await AppModel.shared.hub.broadcast(event: "hazard", Shared(
                    id: id, from: me, kind: kind.rawValue, lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, heading: heading))
            }
            AppModel.shared.show(String(localized: "Danke! \(kind.title) gemeldet."), isError: false)
        } catch {
            Diag.log("Gefahr melden fehlgeschlagen: \(error.localizedDescription)")
            AppModel.shared.show(String(localized: "Meldung nicht möglich – höchstens eine pro Minute."))
        }
    }

    /// Während der Navigation (je Fortschritt): Meldungen auf der Route voraus ansagen, einmal je Meldung
    func check(_ progress: RouteProgress) {
        lastProgress = progress
        guard let shape = progress.route.shape, shape.coordinates.count > 1 else { return }
        if Date().timeIntervalSince(loadedAt) > 300, !loading { Task { await load(shape.coordinates) } }
        for h in items where !announced.contains(h.id) {
            guard h.type != nil, let ahead = Self.ahead(h, progress) else { continue }
            guard ahead > 150, ahead < 2_000 else {
                if ahead <= 150 { announced.insert(h.id) }
                continue
            }
            let type = h.type!
            announced.insert(h.id)
            let source = h.by_friend ? String(localized: "von einem Freund gemeldet") : String(localized: "von Meeterz-Fahrern gemeldet")
            IncidentWatcher.shared.announceReported(title: type.title, subtitle: source, symbol: type.symbol, distance: ahead)
            return
        }
    }

    /// Strecke bis zur Meldung auf der eigenen Route; nil = nicht auf der Route oder Gegenrichtung.
    /// Negativ = schon vorbei.
    private static func ahead(_ h: Hazard, _ progress: RouteProgress) -> Double? {
        guard let shape = progress.route.shape, shape.coordinates.count > 1,
              let snap = shape.closestCoordinate(to: h.coordinate), snap.coordinate.distance(to: h.coordinate) < 40 else { return nil }
        let coords = shape.coordinates
        // Gegenrichtung? Fahrtrichtung der Meldung mit der Richtung der Route an der Stelle vergleichen
        if let heading = h.heading, snap.index + 1 < coords.count {
            let bearing = coords[snap.index].direction(to: coords[snap.index + 1])
            if abs((bearing - heading + 540).truncatingRemainder(dividingBy: 360) - 180) > 60 { return nil }
        }
        // Strecke vom Routenanfang bis zur Meldung
        var along = coords[snap.index].distance(to: snap.coordinate)
        for i in 0..<snap.index { along += coords[i].distance(to: coords[i + 1]) }
        return along - progress.distanceTraveled
    }

    /// Meldung eines Mitfahrenden aus dem Live-Kanal: liegt sie auf meiner Route noch vor mir, sofort Bescheid
    /// sagen („Luca meldet Unfall in 3,2 km“); bei 2 km kommt die übliche Warnung noch einmal.
    func received(_ shared: Shared) {
        guard AppModel.shared.navigation.isNavigating, !items.contains(where: { $0.id == shared.id }) else { return }
        let h = Hazard(id: shared.id, kind: shared.kind, lat: shared.lat, lng: shared.lng, heading: shared.heading, by_friend: true)
        items.append(h)
        guard let type = h.type, let progress = lastProgress, let ahead = Self.ahead(h, progress), ahead > 150 else { return }
        let name = AppModel.shared.friend(shared.from)?.displayName ?? String(localized: "Ein Mitfahrer")
        Diag.log("Konvoi-Gefahr von \(name): \(shared.kind) in \(Int(ahead)) m")
        IncidentWatcher.shared.announceReported(title: type.title, subtitle: String(localized: "\(name) hat es eben gemeldet"),
                                                symbol: type.symbol, distance: ahead)
        if ahead < 2_000 { announced.insert(h.id) }
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
        // Live erhaltene Konvoi-Meldungen behalten, bis sie auch geladen sind
        items = rows + items.filter { h in h.by_friend && !rows.contains { $0.id == h.id } }
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
