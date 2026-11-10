import XCTest
import CoreLocation
@testable import Meeterz

final class StandstillFilterTests: XCTestCase {
    private let start = Date()
    private func loc(_ metersNorth: Double, speed: Double, t: Double) -> CLLocation {
        CLLocation(coordinate: .init(latitude: 51.4 + metersNorth / 111_320, longitude: 6.7), altitude: 30,
                   horizontalAccuracy: 10, verticalAccuracy: 5, course: 0, courseAccuracy: 5,
                   speed: speed, speedAccuracy: 1, timestamp: start.addingTimeInterval(t))
    }

    func testJitterWhileStandingDoesNotMovePosition() {
        var f = StandstillFilter()
        _ = f.filter(loc(0, speed: 8, t: 0))
        _ = f.filter(loc(5, speed: 0.3, t: 1))
        let anchor = f.filter(loc(5, speed: 0.2, t: 2))         // zweite Meldung im Stand: festgehalten
        XCTAssertTrue(f.frozen)
        for (i, jump) in [12.0, -6, 18, 3].enumerated() {       // GPS springt bis 13 m nach vorn
            let out = f.filter(loc(5 + jump, speed: 0.4, t: 3 + Double(i)))
            XCTAssertEqual(out.coordinate.latitude, anchor.coordinate.latitude, accuracy: 1e-9)
            XCTAssertEqual(out.speed, 0)
        }
    }

    func testReleasesAfterTwoMovingReports() {
        var f = StandstillFilter()
        _ = f.filter(loc(0, speed: 0.1, t: 0))
        _ = f.filter(loc(0, speed: 0.1, t: 1))
        XCTAssertTrue(f.frozen)
        let first = f.filter(loc(2, speed: 2.5, t: 2))          // eine Meldung reicht nicht (GPS-Ausreißer)
        XCTAssertTrue(f.frozen)
        XCTAssertEqual(first.speed, 0)
        let second = f.filter(loc(5, speed: 3.5, t: 3))
        XCTAssertFalse(f.frozen)
        XCTAssertEqual(second.speed, 3.5)
    }

    func testFarAwayReleasesImmediately() {
        var f = StandstillFilter()
        _ = f.filter(loc(0, speed: 0, t: 0))
        _ = f.filter(loc(0, speed: 0, t: 1))
        let out = f.filter(loc(200, speed: -1, t: 60))         // nach Funkloch weit weg
        XCTAssertFalse(f.frozen)
        XCTAssertEqual(out.coordinate.latitude, loc(200, speed: 0, t: 0).coordinate.latitude, accuracy: 1e-9)
    }

    func testDrivingPassesThrough() {
        var f = StandstillFilter()
        for i in 0..<5 {
            let input = loc(Double(i) * 14, speed: 14, t: Double(i))
            XCTAssertEqual(f.filter(input).coordinate.latitude, input.coordinate.latitude, accuracy: 1e-12)
        }
        XCTAssertFalse(f.frozen)
    }
}
