import XCTest
@testable import Meeterz
import CoreLocation

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
        XCTAssertEqual(MotorwayDirection.joinFragments(["Duisburg", "-Baerl", "-Homberg", "Moers-Meerbeck"]),
                       ["Duisburg-Baerl", "Duisburg-Homberg", "Moers-Meerbeck"])
        XCTAssertEqual(MotorwayDirection.repairFragments(in: "In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg, -Baerl."),
                       "In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg-Baerl.")
        XCTAssertEqual(MotorwayDirection.repairFragments(in: "Richtung Dortmund, Oberhausen."), "Richtung Dortmund, Oberhausen.")
        XCTAssertEqual(MotorwayDirection.firstTargetOnly(in: "In 800 Metern Auf A 3 in Richtung Arnhem, Hannover über die Ausfahrt 8 abfahren."),
                       "In 800 Metern Auf A 3 in Richtung Arnhem über die Ausfahrt 8 abfahren.")
        XCTAssertEqual(MotorwayDirection.firstTargetOnly(in: "In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg, -Baerl, -Homberg."),
                       "In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg-Baerl.")
        XCTAssertEqual(MotorwayDirection.firstTargetOnly(in: "In Richtung B 7, A 52 nach Rechts abbiegen."), "In Richtung B 7 nach Rechts abbiegen.")
        // Folgeansagen ohne Richtung, und knapp
        XCTAssertEqual(MotorwayDirection.shortExit(MotorwayDirection.withoutDirection("In 800 Metern Auf A 57 in Richtung Köln, Krefeld über die Ausfahrt 8 abfahren.")),
                       "In 800 Metern An der Ausfahrt 8 abfahren.")
        XCTAssertEqual(MotorwayDirection.withoutDirection("In 800 Metern An der Ausfahrt 3 abfahren in Richtung Duisburg, -Baerl."),
                       "In 800 Metern An der Ausfahrt 3 abfahren.")
        XCTAssertEqual(MotorwayDirection.withoutDirection("Rechts halten auf A 42 in Richtung Dortmund, Oberhausen. Dann Rechts halten auf A 42."),
                       "Rechts halten auf A 42. Dann Rechts halten auf A 42.")
        XCTAssertEqual(MotorwayDirection.firstTargetOnly(in: "Rechts halten auf A 42, Richtung Dortmund, Oberhausen. Dann Rechts halten auf A 42."),
                       "Rechts halten auf A 42, Richtung Dortmund. Dann Rechts halten auf A 42.")
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
                       "In 1,5 Kilometern auf die Auffahrt A 3 Richtung Köln fahren.")
        XCTAssertEqual(MotorwayPhrases.phrase(original: "Auf die Auffahrt A 40 abbiegen.", side: "rechts", code: "A 40", targets: ["A 40"]),
                       "Rechts auf die Auffahrt A 40 fahren.")
    }
}

final class ThenCommaTests: XCTestCase {
    // Mapbox: „Dann, in 20 Metern, Links abbiegen.“ – wurde nicht als „dann“ erkannt (31.10.)
    func testThenWithComma() {
        XCTAssertEqual(ThenInstructions.withoutThen("Links auf Aki-Schmidt-Platz abbiegen. Dann, in 20 Metern, Links abbiegen."),
                       "Links auf Aki-Schmidt-Platz abbiegen.")
    }
}

final class ContinueInstructionsTests: XCTestCase {
    func testAnnouncesNextTurnInstead() {
        XCTAssertEqual(ContinueInstructions.rewrite("800 Meter weiter der Route folgen.", maneuver: "Rechts auf Hafenstraße abbiegen."),
                       "In 800 Metern rechts auf Hafenstraße abbiegen.")
        XCTAssertEqual(ContinueInstructions.rewrite("einen Kilometer weiter auf L 140, dann rechts abbiegen.", maneuver: "Rechts abbiegen."),
                       "In einem Kilometer rechts abbiegen.")
        XCTAssertEqual(ContinueInstructions.rewrite("1,5 Kilometer weiter der Route folgen.", maneuver: "An der Ausfahrt abfahren."),
                       "In 1,5 Kilometern an der Ausfahrt abfahren.")
        XCTAssertEqual(ContinueInstructions.rewrite("8 Kilometer weiter der Route folgen.", maneuver: "Rechts auf Ruhrorter Straße abbiegen. Dann Rechts abbiegen."),
                       "In 8 Kilometern rechts auf Ruhrorter Straße abbiegen.")
    }

    func testLeavesOtherTextAlone() {
        XCTAssertNil(ContinueInstructions.rewrite("Rechts abbiegen.", maneuver: "Rechts abbiegen."))
        XCTAssertNil(ContinueInstructions.rewrite("800 Meter weiter der Route folgen.", maneuver: "In 100 Metern rechts abbiegen."))
    }
}

final class EuropeanCodesTests: XCTestCase {
    func testDropsEuropeanNextToNational() {
        XCTAssertEqual(RoadNames.dropEuropeanCodes(in: "Auf A 3/E 35 fahren", national: []), "Auf A 3 fahren")
        XCTAssertEqual(RoadNames.dropEuropeanCodes(in: "Rechts halten auf A 3, E 35 Richtung Köln", national: []), "Rechts halten auf A 3 Richtung Köln")
    }

    func testReplacesEuropeanWithKnownNational() {
        XCTAssertEqual(RoadNames.dropEuropeanCodes(in: "7 Kilometer weiter auf der E 35 fahren.", national: ["A 3"]), "7 Kilometer weiter auf der A 3 fahren.")
    }

    func testKeepsEuropeanWithoutNational() {
        XCTAssertEqual(RoadNames.dropEuropeanCodes(in: "Auf E 45 fahren", national: []), "Auf E 45 fahren")
        XCTAssertEqual(RoadNames.preferredCode(["E 35", "A 3"]), "A 3")
    }
}

final class FrequentPlacesTests: XCTestCase {
    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.timeZone = .current
        return f.date(from: s)!
    }

    func testPredictsWorkOnWeekdayMorning() {
        let home = CLLocationCoordinate2D(latitude: 51.43, longitude: 6.76)
        // Montag–Freitag gegen 08:10 an der Arbeit angekommen (drei Wochen)
        let arrivals = ["2026-10-12 08:10", "2026-10-13 08:05", "2026-10-19 08:12", "2026-10-20 08:08", "2026-10-26 08:15", "2026-10-27 08:02"].map(date)
        let work = FrequentPlaces.Spot(lat: 51.24, lng: 6.78, name: "Arbeit", arrivals: arrivals)
        let gym = FrequentPlaces.Spot(lat: 51.40, lng: 6.70, name: "Sport", arrivals: [date("2026-10-28 19:00")])
        let now = date("2026-11-02 07:45")   // Montag
        XCTAssertEqual(FrequentPlaces.likely(in: [work, gym], now: now, from: home)?.name, "Arbeit")
        // Abends nicht
        XCTAssertNil(FrequentPlaces.likely(in: [work, gym], now: date("2026-11-02 18:00"), from: home))
        // Am Wochenende nicht (andere Art Tag)
        XCTAssertNil(FrequentPlaces.likely(in: [work], now: date("2026-11-07 07:45"), from: home))
        // Schon dort: kein Vorschlag
        XCTAssertNil(FrequentPlaces.likely(in: [work], now: now, from: work.coordinate))
    }
}

final class FinalTurnTests: XCTestCase {
    func testShortFinalTurn() {
        XCTAssertEqual(FinalTurn.short(direction: "rechts", from: "An der nächsten Ampel rechts abbiegen auf Hafenstraße"),
                       "Jetzt rechts abbiegen.")
        XCTAssertEqual(FinalTurn.short(direction: "rechts", from: "Am Ende der Straße rechts abbiegen auf Ruhrorter Straße, dann rechts abbiegen"),
                       "Jetzt rechts abbiegen, dann rechts abbiegen.")
        XCTAssertEqual(FinalTurn.short(direction: "links", from: "Links auf Bergiusstraße abbiegen. Dann Rechts abbiegen."),
                       "Jetzt links abbiegen, dann rechts abbiegen.")
    }
}

final class StepAnnouncementsTests: XCTestCase {
    func testStreetOnlyOnce() {
        XCTAssertEqual(StepAnnouncements.withoutStreet("Rechts auf Friedensstraße abbiegen.", name: "Friedensstraße", code: nil),
                       "Rechts abbiegen.")
        XCTAssertEqual(StepAnnouncements.withoutStreet("An der nächsten Ampel links abbiegen auf Parkstraße", name: "Parkstraße", code: nil),
                       "An der nächsten Ampel links abbiegen")
        XCTAssertEqual(StepAnnouncements.withoutStreet("In 400 Metern Links auf L 473 abbiegen.", name: "Charlottering", code: "L 473"),
                       "In 400 Metern Links abbiegen.")
        XCTAssertEqual(StepAnnouncements.withoutStreet("Links auf L 473, Charlottering abbiegen.", name: "Charlottering", code: "L 473"),
                       "Links abbiegen.")
        XCTAssertEqual(StepAnnouncements.withoutStreet("Rechts halten auf A 42.", name: nil, code: "A 42"), "Rechts halten auf A 42.")
    }
}
