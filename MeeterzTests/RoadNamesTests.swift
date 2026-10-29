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

final class MapboxTextTests: XCTestCase {
    // Echte Mapbox-Texte aus der Probe vom 28.10.
    func testMapboxSentenceStyle() {
        XCTAssertEqual(ThenInstructions.withoutThen("Rechts auf Am Wehrhahn abbiegen. Dann Rechts abbiegen."), "Rechts auf Am Wehrhahn abbiegen.")
        XCTAssertEqual(RoadNames.remove(code: "L 392", from: "Rechts auf Am Wehrhahn, L 392 abbiegen."), "Rechts auf Am Wehrhahn abbiegen.")
    }
}

final class MotorwayDirectionTests: XCTestCase {
    func testDirectionBeforeThenClause() {
        XCTAssertEqual(MotorwayDirection.insert("Richtung Krefeld", into: "Rechts halten auf die Ausfahrt 13. Dann Rechts halten auf A 57."),
                       "Rechts halten auf die Ausfahrt 13, Richtung Krefeld. Dann Rechts halten auf A 57.")
        XCTAssertEqual(MotorwayDirection.insert("Richtung Köln", into: "In 3 Kilometern Rechts halten auf A 3."),
                       "In 3 Kilometern Rechts halten auf A 3, Richtung Köln.")
    }

    func testJoinsDistrictFragments() {
        XCTAssertEqual(MotorwayDirection.joinFragments(["Duisburg", "-Baerl"]), ["Duisburg-Baerl"])
        XCTAssertEqual(MotorwayDirection.joinFragments(["Dortmund", " Oberhausen"]), ["Dortmund", "Oberhausen"])
    }
}

final class MotorwayPhrasesTests: XCTestCase {
    func testOnRampPhrase() {
        XCTAssertEqual(MotorwayPhrases.phrase(original: "In 500 Metern Auf die Auffahrt nach rechts auf A 42 abfahren.",
                                              side: "rechts", code: "A 42", targets: ["Dortmund"]),
                       "In 500 Metern rechts auf die Auffahrt A 42 Richtung Dortmund fahren.")
        XCTAssertEqual(MotorwayPhrases.phrase(original: "Auf die Auffahrt nach rechts auf A 42 abfahren. Dann Links halten.",
                                              side: "rechts", code: "A 42", targets: []),
                       "Rechts auf die Auffahrt A 42 fahren. Dann Links halten.")
        XCTAssertEqual(MotorwayPhrases.phrase(original: "In 1,5 Kilometern Auf die Auffahrt auf A 3 abfahren.",
                                              side: nil, code: "A 3", targets: ["Köln", "Oberhausen"]),
                       "In 1,5 Kilometern auf die Auffahrt A 3 Richtung Köln, Oberhausen fahren.")
    }
}
