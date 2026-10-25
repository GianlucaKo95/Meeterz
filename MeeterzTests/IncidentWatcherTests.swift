import XCTest
@testable import Meeterz

final class IncidentWatcherTests: XCTestCase {
    func testSpokenDistance() {
        XCTAssertEqual(IncidentWatcher.spoken(3_200), "3 Kilometern")
        XCTAssertEqual(IncidentWatcher.spoken(1_100), "einem Kilometer")
        XCTAssertEqual(IncidentWatcher.spoken(760), "800 Metern")
    }
}
