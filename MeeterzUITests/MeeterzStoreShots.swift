import XCTest
import MapKit

/// App-Store-Screenshots mit erfundenen Daten. Läuft nur, wenn SHOT_LANG gesetzt ist (ci/storeshots.sh).
/// Feste Testkonten bekommen erfundene Namen (Alex, Anna, Ben, Mia) und Standorte in Köln; Anna und Ben teilen
/// eine Route (echte Straßen über MapKit). Die App läuft in der gewünschten Sprache; Knöpfe werden über die
/// Übersetzungen der App gefunden (Localizable.xcstrings liegt auch im Testbündel).
final class MeeterzStoreShots: MeeterzTestBase {
    typealias Remote = MeeterzTwoAccountTests.Remote

    private var lang: String { ProcessInfo.processInfo.environment["SHOT_LANG"] ?? "" }
    private var outDir: String { ProcessInfo.processInfo.environment["STORE_SHOT_DIR"] ?? NSTemporaryDirectory() }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(lang.isEmpty, "Nur für App-Store-Screenshots (SHOT_LANG)")
        app = XCUIApplication()
        let locale = ["de": "de_DE", "en": "en_US", "fr": "fr_FR", "es": "es_ES", "pt": "pt_PT", "tr": "tr_TR", "it": "it_IT"][lang] ?? "en_US"
        app.launchArguments += ["-ui.reset", "-dev.simulate", "YES", "-AppleLanguages", "(\(lang == "pt" ? "pt-PT" : lang))", "-AppleLocale", locale]
        app.launch()
    }

    // MARK: Übersetzung der Knopf-Texte

    private static let bundle = Bundle(for: MeeterzStoreShots.self)
    func L(_ key: String) -> String {
        guard lang != "de",
              let path = Self.bundle.path(forResource: lang, ofType: "lproj"),
              let b = Bundle(path: path) else { return key }
        return b.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func storeShot(_ number: Int, _ name: String) {
        let dir = "\(outDir)/\(lang)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let s = XCUIScreen.main.screenshot()
        try? s.pngRepresentation.write(to: URL(fileURLWithPath: String(format: "%@/%02d-%@.png", dir, number, name)))
        shot("store-\(name)")
    }

    func chrome() {
        for _ in 0..<3 {
            let search = app.buttons[L("Ziel suchen")]
            if search.exists && search.isHittable { return }
            tapMap(); pause(1)
        }
    }

    // MARK: Erfundene Route über echte Straßen

    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> (points: [[Double]], seconds: Double) {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = .automobile
        var result: ([[Double]], Double) = ([[from.longitude, from.latitude], [to.longitude, to.latitude]], 900)
        let done = expectation(description: "Route")
        MKDirections(request: req).calculate { resp, _ in
            if let r = resp?.routes.first {
                let n = r.polyline.pointCount
                var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
                r.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
                let step = max(1, n / 120)
                var pts = stride(from: 0, to: n, by: step).map { [coords[$0].longitude, coords[$0].latitude] }
                if let last = coords.last { pts.append([last.longitude, last.latitude]) }
                result = (pts, r.expectedTravelTime)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return result
    }

    // MARK: Ablauf

    func testStoreScreenshots() throws {
        let env = ProcessInfo.processInfo.environment
        let base = env["SB_URL"] ?? "", key = env["SB_KEY"] ?? ""
        try XCTSkipIf(base.isEmpty || key.isEmpty, "SB_URL/SB_KEY fehlen")
        let hp = ["Prefer": "return=minimal"]

        // Ich (in der App) und drei erfundene Freunde
        let me = try XCTUnwrap(Remote.fixed("shot-me", base: base, key: key), "Konto Ich")
        me.request("POST", "/rest/v1/profiles", body: ["id": me.id, "handle": "alex_demo", "display_name": "Alex"], headers: hp)
        let dom = CLLocationCoordinate2D(latitude: 50.9413, longitude: 6.9583)          // Simulator-Standort
        let hafen = CLLocationCoordinate2D(latitude: 50.9262, longitude: 6.9653)        // Ziel von Anna und Ben
        let people: [(role: String, handle: String, name: String, at: CLLocationCoordinate2D, heading: Double, to: CLLocationCoordinate2D?, dest: String?)] = [
            ("shot-anna", "anna_demo", "Anna", .init(latitude: 50.9338, longitude: 6.9302), 110, hafen, "Rheinauhafen"),
            ("shot-ben", "ben_demo", "Ben", .init(latitude: 50.9531, longitude: 6.9852), 200, hafen, "Rheinauhafen"),
            ("shot-mia", "mia_demo", "Mia", .init(latitude: 50.9478, longitude: 6.9411), 0, nil, nil),
        ]
        for p in people {
            let r = try XCTUnwrap(Remote.fixed(p.role, base: base, key: key), "Konto \(p.name)")
            r.request("POST", "/rest/v1/profiles", body: ["id": r.id, "handle": p.handle, "display_name": p.name], headers: hp)
            me.rpc("send_friend_request", ["target_handle": p.handle])
            let rows = try XCTUnwrap(r.rpc("my_friends").1 as? [[String: Any]])
            if let rid = rows.first?["friendship_id"] as? String {
                r.rpc("respond_friend_request", ["request_id": rid, "accept": true])
            }
            r.rpc("update_last_location", ["lat": p.at.latitude, "lng": p.at.longitude, "heading": p.heading, "speed": p.to == nil ? 0.0 : 9.0])
            if let to = p.to, let dest = p.dest {
                let rt = route(from: p.at, to: to)
                r.rpc("set_active_route", ["destination_name": dest, "dest_lat": to.latitude, "dest_lng": to.longitude,
                                          "eta_unix": Date().timeIntervalSince1970 + rt.seconds, "points": rt.points, "travel_mode": "car"])
            }
        }
        _ = dom

        // Anmelden
        need(app.buttons[L("Anmelden")], "login")
        type(Remote.email("shot-me"), into: need(app.textFields[L("E-Mail")], "email-feld"))
        type(Remote.testPassword, into: need(app.secureTextFields[L("Passwort (mind. 6 Zeichen)")], "passwort-feld"))
        app.buttons[L("Anmelden")].tap()
        need(app.buttons[L("Ziel suchen")], "karte", timeout: 60)
        for _ in 0..<3 { tapMap(); pause(3); dismissSystemDialogs() }
        chrome()
        pause(20)    // Freunde und Routen laden, Kacheln zeichnen

        // 1 Karte mit Freunden unterwegs
        chrome()
        storeShot(1, "karte")

        // 2 Unterwegs-Liste
        need(app.buttons[L("Freunde")], "freunde-knopf").tap()
        pause(4)
        storeShot(2, "unterwegs")

        // 3 Fairer Treffpunkt für die Gruppe
        let group = app.buttons[L("Gruppen-Treffen planen")]
        if group.waitForExistence(timeout: 10) {
            group.tap(); pause(2)
            for name in ["Anna", "Ben", "Mia"] {
                let row = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
                if row.waitForExistence(timeout: 5) { row.tap(); pause(1) }
            }
            let find = app.buttons[L("Fairen Treffpunkt finden")]
            if find.waitForExistence(timeout: 5) { find.tap() }
            _ = app.staticTexts[L("Vorschläge – fair für alle")].waitForExistence(timeout: 40)
            pause(3)
            app.swipeUp(); pause(2)
            storeShot(3, "treffpunkt")
            let cancel = app.buttons[L("Abbrechen")]
            if cancel.exists { cancel.tap(); pause(2) }
        }
        if app.buttons[L("Fertig")].exists { app.buttons[L("Fertig")].tap(); pause(2) }

        // 4 Privatsphäre: Teilen-Optionen mit Inkognito
        chrome()
        let pill = app.buttons["status-pill"]
        if pill.waitForExistence(timeout: 5) {
            pill.tap(); pause(2)
            storeShot(4, "privatsphaere")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap(); pause(2)
        }

        // 5 Navigation (simulierte Fahrt) zum Rheinauhafen
        chrome()
        app.buttons[L("Ziel suchen")].tap()
        type("Rheinauhafen Köln", into: need(app.textFields[L("Adresse oder Ort")], "suchfeld"))
        let hit = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Rheinauhafen'")).firstMatch
        need(hit, "suchergebnis", timeout: 30).tap()
        need(app.buttons[L("Losfahren")], "route-vorschau", timeout: 40)
        pause(5)
        storeShot(6, "routenvorschau")
        app.buttons[L("Losfahren")].tap()
        pause(25)
        storeShot(5, "navigation")
    }
}
