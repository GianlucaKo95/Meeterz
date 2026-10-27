import XCTest
@testable import Meeterz

final class LandmarkInstructionsTests: XCTestCase {
    func testPhrases() {
        XCTAssertEqual(LandmarkInstructions.phrase(landmark: .trafficLight, ordinal: 1, direction: "rechts", road: nil),
                       "An der nächsten Ampel rechts abbiegen")
        XCTAssertEqual(LandmarkInstructions.phrase(landmark: .trafficLight, ordinal: 2, direction: "links", road: "Hauptstraße"),
                       "An der zweiten Ampel links abbiegen auf Hauptstraße")
        XCTAssertEqual(LandmarkInstructions.phrase(landmark: .stopSign, ordinal: 2, direction: "links", road: nil),
                       "Am zweiten Stoppschild links abbiegen")
        XCTAssertNil(LandmarkInstructions.phrase(landmark: .trafficLight, ordinal: 4, direction: "rechts", road: nil))
    }
}
