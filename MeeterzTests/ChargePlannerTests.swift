import XCTest
import CoreLocation
@testable import Meeterz

/// Ladeplanung auf einer künstlichen, geraden Autobahnstrecke (Nord-Süd) mit Säulen alle 50 km
final class ChargePlannerTests: XCTestCase {
    let vehicle = EVVehicle(id: "t", brand: "Test", model: "EV", variant: "", year: 2024, battery: 60, consumption: 18,
                            dcMax: 100, curve: [[0, 100], [50, 100], [80, 60], [100, 15]], ports: ["ccs"], estimated: false)

    /// Gerade Strecke von `km` Kilometern bei konstant 120 km/h
    func profile(km: Double) -> ChargePlanner.Profile {
        var p = ChargePlanner.Profile()
        let perKm = ChargePlanner.consumption(kmh: 120, base: vehicle.consumption, temperature: nil)
        for i in 0...Int(km) {
            p.coords.append(CLLocationCoordinate2D(latitude: 52 - Double(i) / 111.32, longitude: 8))
            p.dist.append(Double(i) * 1000)
            p.energy.append(Double(i) * perKm)
            p.time.append(Double(i) * 30)
        }
        return p
    }

    func sites(every km: Double, upTo total: Double, kw: Double = 150) -> [ChargeSite] {
        stride(from: km, to: total, by: km).map {
            ChargeSite(coordinate: .init(latitude: 52 - $0 / 111.32, longitude: 8.002), maxKW: kw, points: 4,
                       name: "Säule \(Int($0))", operatorName: "Test", city: "")
        }
    }

    func testDirectWhenEnoughCharge() throws {
        let plan = try ChargePlanner.plan(profile: profile(km: 100), vehicle: vehicle, startPercent: 90,
                                          settings: .init(), sites: sites(every: 50, upTo: 100)).get()
        XCTAssertTrue(plan.direct)
        XCTAssertGreaterThanOrEqual(plan.arrivalPercent, 20)
    }

    func testLongTripNeedsStopsAndArrivesWithTarget() throws {
        let plan = try ChargePlanner.plan(profile: profile(km: 600), vehicle: vehicle, startPercent: 90,
                                          settings: .init(), sites: sites(every: 50, upTo: 600)).get()
        XCTAssertFalse(plan.stops.isEmpty)
        XCTAssertGreaterThanOrEqual(plan.arrivalPercent, 19)
        for stop in plan.stops {
            XCTAssertGreaterThanOrEqual(stop.arrivalPercent, 9, "nie unter der Mindestladung ankommen")
            XCTAssertLessThanOrEqual(stop.departurePercent, 100)
            XCTAssertGreaterThan(stop.chargeTime, 0)
        }
        // Stopps in Fahrtrichtung sortiert
        XCTAssertEqual(plan.stops.map(\.distanceFromStart), plan.stops.map(\.distanceFromStart).sorted())
        print("Plan 600 km:", plan.summary, plan.stops.map { "\(Int($0.distanceFromStart / 1000)) km \(Int($0.arrivalPercent))→\(Int($0.departurePercent)) %" })
    }

    /// Konvoi-Pause an einer Ladesäule: wird angefahren und dort nach Bedarf geladen
    func testFixedChargerStopIsUsed() throws {
        var settings = ChargePlanner.Settings()
        let pause = ChargeSite(coordinate: .init(latitude: 52 - 120 / 111.32, longitude: 8.002), maxKW: 150, points: 4,
                               name: "Pause", operatorName: "Test", city: "")
        settings.fixed = [.init(site: pause, along: 120_000, offset: 0, fixed: true, canCharge: true)]
        let plan = try ChargePlanner.plan(profile: profile(km: 300), vehicle: vehicle, startPercent: 90,
                                          settings: settings, sites: sites(every: 50, upTo: 300)).get()
        let atPause = try XCTUnwrap(plan.stops.first { $0.fixed })
        XCTAssertEqual(atPause.distanceFromStart, 120_000, accuracy: 1)
        XCTAssertGreaterThan(atPause.chargeTime, 0)
        XCTAssertGreaterThanOrEqual(plan.arrivalPercent, 19)
    }

    /// Reicht der Akku, wird an der Pause nicht geladen
    func testFixedChargerWithoutNeedChargesNothing() throws {
        var settings = ChargePlanner.Settings()
        let pause = ChargeSite(coordinate: .init(latitude: 52 - 50 / 111.32, longitude: 8.002), maxKW: 150, points: 4,
                               name: "Pause", operatorName: "Test", city: "")
        settings.fixed = [.init(site: pause, along: 50_000, offset: 0, fixed: true, canCharge: true)]
        let plan = try ChargePlanner.plan(profile: profile(km: 100), vehicle: vehicle, startPercent: 90,
                                          settings: settings, sites: []).get()
        XCTAssertTrue(plan.direct)
    }

    /// Pause ohne Ladesäule, die mit dem Startakku nicht erreichbar ist: davor wird geladen
    func testFixedStopWithoutChargerGetsStopBefore() throws {
        var settings = ChargePlanner.Settings()
        let pause = ChargeSite(coordinate: .init(latitude: 52 - 100 / 111.32, longitude: 8.002), maxKW: 0, points: 0,
                               name: "Rastplatz", operatorName: "", city: "")
        settings.fixed = [.init(site: pause, along: 100_000, offset: 0, fixed: true, canCharge: false)]
        let plan = try ChargePlanner.plan(profile: profile(km: 300), vehicle: vehicle, startPercent: 50,
                                          settings: settings, sites: sites(every: 50, upTo: 300)).get()
        XCTAssertLessThan(try XCTUnwrap(plan.stops.first).distanceFromStart, 100_000)
        XCTAssertFalse(plan.stops.contains { $0.fixed }, "am Rastplatz ohne Säule wird nicht geladen")
    }

    func testUnreachableWithoutChargers() {
        let result = ChargePlanner.plan(profile: profile(km: 600), vehicle: vehicle, startPercent: 80,
                                        settings: .init(), sites: [])
        guard case .failure(.unreachable) = result else { return XCTFail("müsste unerreichbar sein") }
    }

    func testChargeTimeFollowsCurve() {
        let fast = ChargePlanner.chargeTime(vehicle, from: 10, to: 50, siteKW: 150)
        let slow = ChargePlanner.chargeTime(vehicle, from: 60, to: 100, siteKW: 150)
        XCTAssertGreaterThan(slow, fast * 2, "oben herum lädt es deutlich langsamer")
        // 24 kWh bei 100 kW und 92 % Wirkungsgrad ≈ 15,7 Min.
        XCTAssertEqual(fast / 60, 15.7, accuracy: 1)
    }

    func testReplanFromMidRoute() throws {
        let full = profile(km: 600)
        let rest = full.suffix(from: 300_000)
        XCTAssertEqual(rest.dist.last ?? 0, 300_000, accuracy: 1)
        XCTAssertEqual(rest.energy(from: 0, to: 100_000), full.energy(from: 300_000, to: 400_000), accuracy: 0.01)
        let plan = try ChargePlanner.plan(profile: rest, vehicle: vehicle, startPercent: 50, settings: .init(),
                                          sites: sites(every: 50, upTo: 600)).get()
        XCTAssertTrue(plan.stops.allSatisfy { $0.distanceFromStart >= 0 && $0.distanceFromStart <= 300_000 })
        XCTAssertGreaterThanOrEqual(plan.arrivalPercent, 19)
    }

    // MARK: Höhe und Wetter

    /// 100 km nach Süden bei 120 km/h, optional mit Höhen und konstantem Wetter
    func points(km: Int) -> [ChargePlanner.RoutePoint] {
        (0...km).map { i in
            ChargePlanner.RoutePoint(coordinate: .init(latitude: 52 - Double(i) / 111.32, longitude: 8),
                                     dist: Double(i) * 1000, time: Double(i) * 30, kmh: 120)
        }
    }

    func conditions(heights: [(Double, Double)] = [], windFrom: Double? = nil, wind: Double = 10, temp: Double = 20, rain: Double = 0) -> RouteConditions {
        var c = RouteConditions()
        c.heights = heights.map { RouteConditions.Height(dist: $0.0, meters: $0.1) }
        if let windFrom {
            let now = Date().timeIntervalSince1970 - 60
            c.weather = [RouteConditions.Weather(dist: 0, times: [now, now + 3600, now + 7200], temperature: [temp, temp, temp],
                                                 wind: [wind, wind, wind], windFrom: [windFrom, windFrom, windFrom], rain: [rain, rain, rain])]
        }
        return c
    }

    func energy(_ c: RouteConditions?) -> Double {
        ChargePlanner.profile(points: points(km: 100), vehicle: vehicle, temperature: 20, conditions: c).energy.last!
    }

    func testWithoutConditionsMatchesFlatModel() {
        let flat = ChargePlanner.consumption(kmh: 120, base: vehicle.consumption, temperature: 20) * 100
        XCTAssertEqual(energy(nil), flat, accuracy: 0.01)
    }

    func testClimbCostsAndDescentPartlyReturns() {
        let flat = energy(nil)
        // 500 m hinauf: m·g·h ≈ 1720 kg · 9,81 · 500 m ≈ 2,3 kWh, bei 90 % ≈ 2,6 kWh mehr
        let up = energy(conditions(heights: [(0, 0), (100_000, 500)]))
        XCTAssertEqual(up - flat, ChargePlanner.mass(of: vehicle) * 9.81 * 500 / 3_600_000 / 0.9, accuracy: 0.05)
        // Sanftes Gefälle (0,5 %): verbraucht weniger, aber nie weniger als null
        let down = energy(conditions(heights: [(0, 500), (100_000, 0)]))
        XCTAssertLessThan(down, flat)
        // Hin und zurück über einen Berg kostet mehr als eben (Verluste)
        let hill = energy(conditions(heights: [(0, 0), (50_000, 500), (100_000, 0)]))
        XCTAssertGreaterThan(hill, flat)
    }

    func testSteepDescentRecuperatesOnlyPart() {
        // 1 km mit 10 % Gefälle: Lageenergie übersteigt den Fahrverbrauch, vom Überschuss kommen 65 % zurück
        let e = ChargePlanner.segmentEnergy(meters: 1000, flatPerMeter: 0.0002, climb: -100, mass: 1700)
        let lift = 1700 * 9.81 * 100 / 3_600_000.0
        XCTAssertEqual(e, (0.2 - lift) * 0.65, accuracy: 0.0001)
    }

    func testHeadwindCostsTailwindSaves() {
        let flat = energy(nil)
        // Fahrt nach Süden (180°): Wind aus Süden ist Gegenwind, aus Norden Rückenwind, aus Osten Seitenwind
        XCTAssertGreaterThan(energy(conditions(windFrom: 180)), flat * 1.05)
        XCTAssertLessThan(energy(conditions(windFrom: 0)), flat * 0.95)
        XCTAssertEqual(energy(conditions(windFrom: 90)), flat, accuracy: 0.05)
    }

    func testForecastColdAndRainRaiseConsumption() {
        let flat = energy(nil)
        XCTAssertGreaterThan(energy(conditions(windFrom: 90, wind: 0, temp: 0)), flat * 1.1)
        XCTAssertGreaterThan(energy(conditions(windFrom: 90, wind: 0, rain: 3)), flat * 1.05)
    }

    func testBearing() {
        let a = CLLocationCoordinate2D(latitude: 52, longitude: 8)
        XCTAssertEqual(a.bearing(to: .init(latitude: 51, longitude: 8)), 180, accuracy: 0.5)
        XCTAssertEqual(a.bearing(to: .init(latitude: 52, longitude: 9)), 90, accuracy: 1)
    }

    func testLearnedFactorRaisesConsumption() {
        var s = ChargePlanner.Settings()
        s.factors = [1, 1, 1.2]
        XCTAssertEqual(s.factor(kmh: 130), 1.2)
        XCTAssertEqual(s.factor(kmh: 50), 1)
    }

    func testBundledData() {
        XCTAssertGreaterThan(ChargeSites.all.count, 5_000)
        XCTAssertGreaterThan(EVCatalog.all.count, 500)
        XCTAssertTrue(EVCatalog.all.contains { $0.brand == "MG" && $0.model.contains("MG5") })
    }
}
