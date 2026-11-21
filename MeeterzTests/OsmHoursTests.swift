import XCTest
@testable import Meeterz

final class OsmHoursTests: XCTestCase {
    func testTypischeWoche() throws {
        let h = try XCTUnwrap(OsmPlaces.parse("Mo,We-Sa 17:00-23:00; Tu off; Su 12:00-21:30; PH off"))
        XCTAssertEqual(h[0], [1020..<1380])
        XCTAssertEqual(h[1], [])
        XCTAssertEqual(h[5], [1020..<1380])
        XCTAssertEqual(h[6], [720..<1290])
    }

    func testMittagspauseUndMitternacht() throws {
        let h = try XCTUnwrap(OsmPlaces.parse("Mo-Fr 11:30-14:00,18:00-01:00"))
        XCTAssertEqual(h[4], [690..<840, 1080..<1500])
        XCTAssertEqual(h[5], [])
    }

    func testRundUmDieUhrUndUnbekannt() {
        XCTAssertEqual(OsmPlaces.parse("24/7")?[3], [0..<1440])
        XCTAssertNil(OsmPlaces.parse("Jan-Mar Mo-Fr 10:00-12:00"))
    }
}

final class StoryDecodingTests: XCTestCase {
    /// So kommt eine Story aus friend_stories (4 Nachkommastellen im Zeitstempel)
    func testStoryAusDerDatenbank() throws {
        let json = #"[{"id":"91bb4b7d-f27a-40b4-b339-bd99033179f2","user_id":"f2cb5a5a-199d-4950-91b3-15a9d2679886","display_name":"G K","kind":"photo","media_path":"a/b.jpg","lat":51.49,"lng":6.67,"place_name":"Waldstraße 1C","caption":null,"convoy_key":null,"created_at":"2026-11-17T21:11:57.8161+00:00","expires_at":"2026-11-18T21:11:57.8161+00:00","seen":false}]"#
        let rows = try JSONDecoder().decode([StoriesStore.Story].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].createdAt.timeIntervalSince1970, 1_794_949_917.816, accuracy: 0.01)
    }
}

@MainActor
final class SteadyLocationTests: XCTestCase {
    func testSprungImStandWirdVerworfen() {
        XCTAssertFalse(SteadyLocation.plausible(distance: 40, seconds: 1, speed: 0))
        XCTAssertTrue(SteadyLocation.plausible(distance: 10, seconds: 1, speed: 0))
    }
    func testFahrtWirdUebernommen() {
        XCTAssertTrue(SteadyLocation.plausible(distance: 30, seconds: 1, speed: 28))   // ~100 km/h
        XCTAssertTrue(SteadyLocation.plausible(distance: 200, seconds: 10, speed: 15))
    }
}
