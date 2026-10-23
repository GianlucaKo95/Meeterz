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
