import XCTest
@testable import Meeterz

final class RoadNamesTests: XCTestCase {
    func testDropsCodeNextToName() {
        XCTAssertEqual(RoadNames.remove(code: "L 91", from: "Rechts abbiegen auf Hauptstraße/L 91"), "Rechts abbiegen auf Hauptstraße")
        XCTAssertEqual(RoadNames.remove(code: "L 91", from: "Rechts abbiegen auf L 91/Hauptstraße"), "Rechts abbiegen auf Hauptstraße")
        XCTAssertEqual(RoadNames.remove(code: "L 91", from: "Links abbiegen auf Hauptstraße (L 91)."), "Links abbiegen auf Hauptstraße.")
        XCTAssertEqual(RoadNames.remove(code: "L 91", from: "Weiter auf Hauptstraße, L91"), "Weiter auf Hauptstraße")
    }

    func testKeepsCodeWhenItIsTheOnlyReference() {
        XCTAssertEqual(RoadNames.remove(code: "L 91", from: "Weiter auf L 91"), "Weiter auf L 91")
    }
}

final class ThenInstructionsTests: XCTestCase {
    func testRemovesThenClause() {
        XCTAssertEqual(ThenInstructions.withoutThen("Rechts abbiegen, dann links abbiegen."), "Rechts abbiegen.")
        XCTAssertEqual(ThenInstructions.withoutThen("In 200 Metern rechts abbiegen auf Hauptstraße, dann links abbiegen"),
                       "In 200 Metern rechts abbiegen auf Hauptstraße")
    }
}
