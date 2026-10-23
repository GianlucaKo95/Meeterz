import Foundation
import CoreLocation
import MapboxDirections

/// Schnellladestandort (Bundesnetzagentur-Register, Deutschland; sonst Mapbox-Suche ohne Leistungsangabe)
struct ChargeSite: Hashable {
    let coordinate: CLLocationCoordinate2D
    let maxKW: Double
    let points: Int
    let name: String
    let operatorName: String
    let city: String
    /// Ländercode (DE, FR, CH, …)
    var country: String = "DE"

    /// Leistung aus der Quelle bekannt? Sonst rechnet die Planung vorsichtig mit 50 kW
    var powerKnown: Bool { maxKW > 0 }
    var plannedKW: Double { powerKnown ? maxKW : 50 }

    var title: String { name == operatorName || name.isEmpty ? "\(Self.short(operatorName)) \(city)" : name }

    /// „EnBW mobility+ AG und Co.KG“ → „EnBW mobility+“
    static func short(_ name: String) -> String {
        var n = name
        for suffix in [" GmbH & Co. KG", " GmbH & Co.KG", " AG und Co.KG", " AG & Co. KG", " GmbH", " AG", " SE", " mbH", " KG", " e.V."] {
            if let r = n.range(of: suffix) { n = String(n[..<r.lowerBound]) }
        }
        return n.trimmingCharacters(in: .whitespaces)
    }

    static func == (a: ChargeSite, b: ChargeSite) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
    func hash(into h: inout Hasher) { h.combine(coordinate.latitude); h.combine(coordinate.longitude) }
}

/// Gebündelte Schnelllader (tools/build_chargers.py, CC BY 4.0 Bundesnetzagentur.de)
enum ChargeSites {
    static let attribution = "Ladesäulen: Bundesnetzagentur.de (CC BY 4.0), data.gouv.fr IRVE, Bundesamt für Energie, Open Charge Map (CC BY 4.0), © OpenStreetMap-Mitwirkende (ODbL)"

    /// Deutschland (BNetzA) und Nachbarländer/Italien (IRVE, BFE, OpenStreetMap)
    static let all: [ChargeSite] = load("chargers-de") + load("chargers-eu")

    private static func load(_ resource: String) -> [ChargeSite] {
        struct File: Decodable { let sites: [[Value]] }
        enum Value: Decodable {
            case n(Double), s(String)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let v = try? c.decode(Double.self) { self = .n(v) } else { self = .s((try? c.decode(String.self)) ?? "") }
            }
            var double: Double { if case .n(let v) = self { return v }; return 0 }
            var string: String { if case .s(let v) = self { return v }; return "" }
        }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.sites.compactMap { r in
            guard r.count >= 7 else { return nil }
            return ChargeSite(coordinate: .init(latitude: r[0].double, longitude: r[1].double), maxKW: r[2].double,
                              points: Int(r[3].double), name: r[4].string, operatorName: r[5].string, city: r[6].string,
                              country: r.count > 7 ? r[7].string : "DE")
        }
    }
}

/// Ladeplanung wie bei ABRP: Ankunft mit Ziel-Akkustand, Stopps so gewählt, dass Fahr- plus Ladezeit minimal ist.
///
/// Energiemodell: Durchschnittsverbrauch des Fahrzeugs, nach Tempo je Routenabschnitt skaliert (Luftwiderstand
/// wächst quadratisch) und bei Kälte erhöht. Ladezeit aus der Ladekurve des Fahrzeugs, begrenzt durch die Säule.
/// Suche: kürzeste Gesamtzeit über (Säule, Ankunfts-Akkustand); an jeder Säule wird nur so viel geladen,
/// wie bis zum nächsten Stopp bzw. Ziel nötig ist – das ist bei abfallender Ladekurve zeitoptimal.
enum ChargePlanner {
    struct Settings {
        var arrivalPercent: Double = 20
        var minAtChargerPercent: Double = 10
        var maxChargePercent: Double = 100
        /// Feste Zeit je Stopp (Abfahrt, Anschließen, Bezahlen)
        var stopOverhead: TimeInterval = 4 * 60
        var temperature: Double?
    }

    struct Stop: Identifiable, Hashable {
        let site: ChargeSite
        let distanceFromStart: Double
        let arrivalPercent: Double
        let departurePercent: Double
        let chargeTime: TimeInterval
        var id: ChargeSite { site }
        var place: Place {
            Place(id: "charge-\(site.coordinate.latitude),\(site.coordinate.longitude)", name: site.title,
                  address: "\(site.operatorName) · \(site.powerKnown ? "\(Int(site.maxKW)) kW" : "Leistung unbekannt")", coordinate: site.coordinate, symbol: "bolt.car.fill")
        }
    }

    struct Plan: Equatable {
        let stops: [Stop]
        let arrivalPercent: Double
        let startPercent: Double
        let totalChargeTime: TimeInterval
        let driveTime: TimeInterval
        /// Ohne Laden erreichbar?
        var direct: Bool { stops.isEmpty }

        /// „2 Ladestopps · 35 Min. laden · Ankunft mit 21 %“
        var summary: String {
            if direct { return "Kein Ladestopp nötig · Ankunft mit \(Int(arrivalPercent.rounded())) %" }
            let n = stops.count == 1 ? "1 Ladestopp" : "\(stops.count) Ladestopps"
            return "\(n) · \(Int((totalChargeTime / 60).rounded())) Min. laden · Ankunft mit \(Int(arrivalPercent.rounded())) %"
        }
    }

    enum Failure: Error, Equatable {
        case noVehicle
        case unreachable(reachKm: Double)
    }

    // MARK: Route aufbereiten

    /// Punkte entlang der Route mit aufsummierter Strecke (m), Zeit (s) und Energie (kWh)
    struct Profile {
        var coords: [CLLocationCoordinate2D] = []
        var dist: [Double] = []
        var energy: [Double] = []
        var time: [Double] = []

        func energy(from a: Double, to b: Double) -> Double { value(energy, at: b) - value(energy, at: a) }
        func time(from a: Double, to b: Double) -> Double { value(time, at: b) - value(time, at: a) }

        private func value(_ arr: [Double], at d: Double) -> Double {
            guard let last = dist.last, !dist.isEmpty else { return 0 }
            if d <= 0 { return arr[0] }
            if d >= last { return arr[arr.count - 1] }
            var lo = 0, hi = dist.count - 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if dist[mid] <= d { lo = mid } else { hi = mid } }
            let t = (d - dist[lo]) / max(dist[hi] - dist[lo], 0.01)
            return arr[lo] + (arr[hi] - arr[lo]) * t
        }
    }

    /// Verbrauch (kWh/km) bei einem Tempo: Durchschnitt gilt für ca. 75 km/h; 28 % davon Luftwiderstand
    static func consumption(kmh: Double, base: Double, temperature: Double?) -> Double {
        let v = min(max(kmh, 15), 200)
        var c = base / 100 * (0.72 + 0.28 * pow(v / 75, 2))
        if let t = temperature, t < 15 { c *= 1 + min(0.3, (15 - t) * 0.012) }   // Heizung, kalter Akku
        return c
    }

    static func profile(of route: Route, vehicle: EVVehicle, temperature: Double?) -> Profile {
        var p = Profile()
        var d = 0.0, e = 0.0, t = 0.0
        for leg in route.legs {
            for step in leg.steps {
                guard let shape = step.shape?.coordinates, shape.count > 1, step.distance > 0 else { continue }
                let kmh = step.expectedTravelTime > 0 ? step.distance / step.expectedTravelTime * 3.6 : 50
                let perMeter = consumption(kmh: kmh, base: vehicle.consumption, temperature: temperature) / 1000
                let secondsPerMeter = step.expectedTravelTime / step.distance
                // Formlänge auf die Schrittlänge normieren
                var shapeLen = 0.0
                for (a, b) in zip(shape, shape.dropFirst()) { shapeLen += a.distance(to: b) }
                let scale = shapeLen > 0 ? step.distance / shapeLen : 1
                if p.coords.isEmpty { p.coords.append(shape[0]); p.dist.append(0); p.energy.append(0); p.time.append(0) }
                for (a, b) in zip(shape, shape.dropFirst()) {
                    let m = a.distance(to: b) * scale
                    d += m; e += m * perMeter; t += m * secondsPerMeter
                    p.coords.append(b); p.dist.append(d); p.energy.append(e); p.time.append(t)
                }
            }
        }
        return p
    }

    // MARK: Säulen entlang der Route

    struct Candidate {
        let site: ChargeSite
        /// Meter ab Start
        let along: Double
        /// Abstand zur Route (Umweg hin und zurück)
        let offset: Double
    }

    static func candidates(along p: Profile, sites: [ChargeSite], corridor: Double = 2_500) -> [Candidate] {
        guard p.coords.count > 1 else { return [] }
        // Raster über die Routenpunkte (~2 km), damit nicht jede Säule gegen jeden Punkt gerechnet wird
        let cell = 0.02
        var grid: [Int64: [Int]] = [:]
        func key(_ c: CLLocationCoordinate2D) -> (Int, Int) { (Int(floor(c.latitude / cell)), Int(floor(c.longitude / cell))) }
        func hash(_ k: (Int, Int)) -> Int64 { Int64(k.0) << 32 | Int64(UInt32(bitPattern: Int32(k.1))) }
        for (i, c) in p.coords.enumerated() { grid[hash(key(c)), default: []].append(i) }
        let lats = p.coords.map(\.latitude), lngs = p.coords.map(\.longitude)
        let minLat = lats.min()! - 0.05, maxLat = lats.max()! + 0.05, minLng = lngs.min()! - 0.07, maxLng = lngs.max()! + 0.07

        var result: [Candidate] = []
        for s in sites {
            let c = s.coordinate
            guard c.latitude > minLat, c.latitude < maxLat, c.longitude > minLng, c.longitude < maxLng else { continue }
            let k = key(c)
            var best = (i: -1, d: Double.greatestFiniteMagnitude)
            for dy in -1...1 { for dx in -1...1 {
                for i in grid[hash((k.0 + dy, k.1 + dx))] ?? [] {
                    let d = p.coords[i].distance(to: c)
                    if d < best.d { best = (i, d) }
                }
            } }
            guard best.i >= 0, best.d <= corridor else { continue }
            result.append(Candidate(site: s, along: p.dist[best.i], offset: best.d))
        }
        // Je 5 km die zwei besten (stärkste Leistung, wenig Umweg) – hält die Suche klein
        let grouped = Dictionary(grouping: result) { Int($0.along / 5_000) }
        return grouped.values.flatMap { group in
            group.sorted { ($0.site.plannedKW - $0.offset / 50) > ($1.site.plannedKW - $1.offset / 50) }.prefix(2)
        }
        .sorted { $0.along < $1.along }
    }

    // MARK: Ladezeit

    /// Sekunden, um von `from` auf `to` Prozent zu laden (Ladekurve, Säulenleistung, 92 % Wirkungsgrad)
    static func chargeTime(_ vehicle: EVVehicle, from: Double, to: Double, siteKW: Double) -> TimeInterval {
        guard to > from else { return 0 }
        var seconds = 0.0
        var p = from
        let kwhPerPercent = vehicle.battery / 100
        while p < to {
            let step = min(1, to - p)
            let power = max(3, min(vehicle.chargingPower(atPercent: p + step / 2), siteKW, vehicle.dcMax ?? siteKW))
            seconds += kwhPerPercent * step / (power * 0.92) * 3600
            p += step
        }
        return seconds
    }

    // MARK: Planen

    struct State: Hashable { let node: Int; let soc: Int }
    struct Entry { let cost: Double; let state: State }

    /// Binärer Min-Heap nach Kosten
    struct MinHeap {
        private var items: [Entry] = []
        mutating func push(_ e: Entry) {
            items.append(e)
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard items[i].cost < items[parent].cost else { break }
                items.swapAt(i, parent); i = parent
            }
        }
        mutating func pop() -> Entry? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l].cost < items[m].cost { m = l }
                if r < items.count, items[r].cost < items[m].cost { m = r }
                if m == i { break }
                items.swapAt(i, m); i = m
            }
            return top
        }
    }

    static func plan(route: Route, vehicle: EVVehicle, startPercent: Double, settings: Settings,
                     sites: [ChargeSite]) -> Result<Plan, Failure> {
        plan(profile: profile(of: route, vehicle: vehicle, temperature: settings.temperature),
             vehicle: vehicle, startPercent: startPercent, settings: settings, sites: sites)
    }

    static func plan(profile p: Profile, vehicle: EVVehicle, startPercent: Double, settings: Settings,
                     sites: [ChargeSite]) -> Result<Plan, Failure> {
        guard let total = p.dist.last, total > 0 else { return .failure(.unreachable(reachKm: 0)) }
        let pct = { (kwh: Double) in kwh / vehicle.battery * 100 }
        let cands = candidates(along: p, sites: sites)

        // Direkt erreichbar?
        let directArrival = startPercent - pct(p.energy(from: 0, to: total))
        if directArrival >= settings.arrivalPercent {
            return .success(Plan(stops: [], arrivalPercent: directArrival, startPercent: startPercent,
                                 totalChargeTime: 0, driveTime: p.time(from: 0, to: total)))
        }

        // Knoten: 0 = Start, 1...n = Säulen, n+1 = Ziel. Zustand: (Knoten, Ankunfts-% in ganzen Prozent)
        let n = cands.count
        let destination = n + 1
        func along(_ i: Int) -> Double { i == 0 ? 0 : (i == destination ? total : cands[i - 1].along) }
        func detourEnergy(_ i: Int) -> Double { i == 0 || i == destination ? 0 : pct(cands[i - 1].offset * 2 / 1000 * vehicle.consumption / 100) }
        func detourTime(_ i: Int) -> Double { i == 0 || i == destination ? 0 : cands[i - 1].offset * 2 / 1000 / 40 * 3600 }

        var best: [State: Double] = [:]
        var previous: [State: (State, Double, Double)] = [:]   // Vorgänger, Abfahrts-%, Ladezeit
        var queue = MinHeap()

        func push(_ s: State, _ cost: Double, from: State?, depart: Double, charge: Double) {
            guard cost < best[s] ?? .greatestFiniteMagnitude else { return }
            best[s] = cost
            if let from { previous[s] = (from, depart, charge) }
            queue.push(Entry(cost: cost, state: s))
        }

        let start = State(node: 0, soc: Int(startPercent.rounded(.down)))
        push(start, 0, from: nil, depart: startPercent, charge: 0)
        var goal: State?

        while let current = queue.pop() {
            let s = current.state
            guard current.cost <= best[s] ?? .greatestFiniteMagnitude else { continue }
            if s.node == destination { goal = s; break }
            let arrival = s.node == 0 ? startPercent : Double(s.soc)
            let here = along(s.node)
            let siteKW = s.node == 0 ? 0 : cands[s.node - 1].site.plannedKW

            for j in (s.node + 1)...destination {
                let there = along(j)
                guard there > here + (j == destination ? 0 : 5_000) else { continue }
                let need = pct(p.energy(from: here, to: there)) + detourEnergy(s.node) / 2 + detourEnergy(j) / 2
                let minArrival = j == destination ? settings.arrivalPercent : settings.minAtChargerPercent
                let requiredDeparture = need + minArrival
                if requiredDeparture > settings.maxChargePercent { break }      // weiter geht's mit keiner Ladung
                var depart = arrival
                var charge = 0.0
                if s.node == 0 {
                    guard arrival >= requiredDeparture else { continue }        // am Start wird nicht geladen
                } else {
                    guard requiredDeparture > arrival else { continue }         // anhalten ohne zu laden lohnt nicht
                    depart = requiredDeparture
                    charge = chargeTime(vehicle, from: arrival, to: depart, siteKW: siteKW) + settings.stopOverhead
                }
                let drive = p.time(from: here, to: there) + detourTime(s.node) / 2 + detourTime(j) / 2
                let next = State(node: j, soc: Int((depart - need).rounded(.down)))
                push(next, current.cost + drive + charge, from: s, depart: depart, charge: charge)
            }
        }

        guard let goal else {
            let reach = (startPercent - settings.minAtChargerPercent) / 100 * vehicle.battery
                / max(p.energy(from: 0, to: total) / total * 1000, 0.05)
            return .failure(.unreachable(reachKm: reach))
        }

        // Weg zurückverfolgen
        var stops: [Stop] = []
        var s = goal
        var totalCharge = 0.0
        while let (prev, depart, charge) = previous[s] {
            if prev.node != 0 {
                let c = cands[prev.node - 1]
                stops.insert(Stop(site: c.site, distanceFromStart: c.along, arrivalPercent: Double(prev.soc),
                                  departurePercent: depart, chargeTime: charge - settings.stopOverhead), at: 0)
                totalCharge += charge - settings.stopOverhead
            }
            s = prev
        }
        return .success(Plan(stops: stops, arrivalPercent: Double(goal.soc), startPercent: startPercent,
                             totalChargeTime: totalCharge, driveTime: p.time(from: 0, to: total)))
    }
}

/// Einstellungen der Ladeplanung
extension EVSettings {
    /// Gewünschter Akkustand bei Ankunft (%)
    static var arrivalPercent: Double {
        get { UserDefaults.standard.object(forKey: "ev.arrival") as? Double ?? 20 }
        set { UserDefaults.standard.set(newValue, forKey: "ev.arrival") }
    }
    /// Mindestens an der Ladesäule (%)
    static var minAtChargerPercent: Double {
        get { UserDefaults.standard.object(forKey: "ev.minCharger") as? Double ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "ev.minCharger") }
    }

    @MainActor static var plannerSettings: ChargePlanner.Settings {
        var s = ChargePlanner.Settings()
        s.arrivalPercent = arrivalPercent
        s.minAtChargerPercent = minAtChargerPercent
        s.temperature = AppModel.shared.vehicle.status?.extTemp
        return s
    }

    /// Ladeplan für eine Route mit den aktuellen Einstellungen (nil, wenn kein E-Auto/Fahrzeug)
    @MainActor static func plan(for route: Route) async -> Result<ChargePlanner.Plan, ChargePlanner.Failure>? {
        guard enabled, let vehicle else { return nil }
        let start = chargePercent
        let settings = plannerSettings
        return await Task.detached(priority: .userInitiated) {
            ChargePlanner.plan(route: route, vehicle: vehicle, startPercent: start, settings: settings,
                               sites: ChargeSites.all)
        }.value
    }
}
