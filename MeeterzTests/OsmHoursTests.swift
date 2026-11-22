import XCTest
import CoreLocation
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

@MainActor
final class SteadyLocationDirectionTests: XCTestCase {
    func testHinterDerFahrtrichtung() {
        let a = CLLocationCoordinate2D(latitude: 51.4, longitude: 6.7)
        let north = CLLocationCoordinate2D(latitude: 51.4003, longitude: 6.7)
        let south = CLLocationCoordinate2D(latitude: 51.3997, longitude: 6.7)
        XCTAssertFalse(SteadyLocation.behind(from: a, to: north, course: 0))
        XCTAssertTrue(SteadyLocation.behind(from: a, to: south, course: 0))
        XCTAssertEqual(SteadyLocation.angle(350, 10), 20, accuracy: 0.01)
    }
}

final class SearchRankingTests: XCTestCase {
    private func place(_ name: String, _ lat: Double, _ lng: Double, id: String = UUID().uuidString) -> Place {
        Place(id: id, name: name, address: nil, coordinate: .init(latitude: lat, longitude: lng))
    }
    private let duisburg = CLLocationCoordinate2D(latitude: 51.43, longitude: 6.76)

    func testPassendesNahesVorFalschemFernem() {
        let near = place("Boda Borg Duisburg", 51.44, 6.78)
        let wrong = place("Bodensee-Therme", 47.6, 9.4)
        let far = place("Boda Borg Stockholm", 59.3, 18.0)
        let out = SearchRanking.merge(apple: [], mapbox: [wrong, far, near], query: "Boda Borg", near: duisburg)
        XCTAssertEqual(out.first?.name, "Boda Borg Duisburg")
        XCTAssertFalse(out.contains { $0.name == "Bodensee-Therme" })   // kein Wort passt
    }

    func testDoppelterOrtNurEinmal() {
        let a = place("Boda Borg", 51.4400, 6.7800, id: "apple")
        let m = place("Boda Borg", 51.4401, 6.7801, id: "mapbox")
        let out = SearchRanking.merge(apple: [a], mapbox: [m], query: "boda", near: duisburg)
        XCTAssertEqual(out.map(\.id), ["apple"])
    }

    func testOhneJedeUebereinstimmungBleibtAllesStehen() {
        let out = SearchRanking.merge(apple: [], mapbox: [place("Hbf", 51.43, 6.77)], query: "Hauptbahnhof", near: duisburg)
        XCTAssertEqual(out.count, 1)
    }
}
