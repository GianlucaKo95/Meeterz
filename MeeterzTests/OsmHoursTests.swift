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
