import XCTest

/// Live-Position und Navigation im Simulator.
/// A und B sind über das Backend bereits befreundet; A meldet sich in der App an.
/// B sendet Positionen über den Realtime-Broadcast (wie die App) – A muss den Marker wandern sehen.
/// Danach plant A eine Route (Düsseldorf Hbf) und fährt los (simulierte Fahrt, Live-Verkehr über Mapbox).
final class MeeterzZLiveNavTests: MeeterzTestBase {
    override var shotPrefix: String { "nav" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ui.reset", "-dev.simulate", "YES", "-map.satellite", "YES"]   // Satellit erzwingen       // simulierte Fahrt statt echter Ortung
        app.launch()
    }

    private func distanceLabel() -> String? {
        let p = NSPredicate(format: "label MATCHES '^[0-9.,]+ (m|km)$'")
        let el = app.staticTexts.matching(p).firstMatch
        return el.exists ? el.label : nil
    }

    func testLiveUndNavigation() throws {
        let env = ProcessInfo.processInfo.environment
        let base = env["SB_URL"] ?? ""
        let key = env["SB_KEY"] ?? ""
        try XCTSkipIf(base.isEmpty || key.isEmpty, "SB_URL/SB_KEY fehlen")
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let emailA = "ci-na-\(suffix)@example.com", passA = "Ci-na-\(suffix)-pw"

        // A und B anlegen, befreunden, B in der Nähe platzieren
        let a = try XCTUnwrap(MeeterzTwoAccountTests.Remote.signUp(base: base, key: key, email: emailA, password: passA), "Konto A")
        let b = try XCTUnwrap(MeeterzTwoAccountTests.Remote.signUp(base: base, key: key, email: "ci-nb-\(suffix)@example.com", password: "Ci-nb-\(suffix)-pw"), "Konto B")
        let hp: [String: String] = ["Prefer": "return=minimal"]
        a.request("POST", "/rest/v1/profiles", body: ["id": a.id, "handle": "na_\(suffix)", "display_name": "Al Alpha"], headers: hp)
        b.request("POST", "/rest/v1/profiles", body: ["id": b.id, "handle": "nb_\(suffix)", "display_name": "Bea Beta"], headers: hp)
        defer { a.rpc("delete_account"); b.rpc("delete_account") }
        a.rpc("send_friend_request", ["target_handle": "nb_\(suffix)"])
        let rows = try XCTUnwrap(b.rpc("my_friends").1 as? [[String: Any]])
        let rid = try XCTUnwrap(rows.first?["friendship_id"] as? String)
        XCTAssertLessThan(b.rpc("respond_friend_request", ["request_id": rid, "accept": true]).0, 300)

        var lat = 51.4352, lng = 6.7641
        func broadcast() -> Int {
            let payload: [String: Any] = ["userId": b.id.uppercased(), "lat": lat, "lng": lng, "heading": 0.0, "speed": 12.0,
                                          "ts": Date().timeIntervalSince1970]
            return b.request("POST", "/realtime/v1/api/broadcast",
                             body: ["messages": [["topic": "loc:\(b.id)", "event": "pos", "payload": payload, "private": true]]]).0
        }
        b.rpc("update_last_location", ["lat": lat, "lng": lng, "heading": 0.0, "speed": 12.0])

        // A meldet sich an
        need(app.buttons["Anmelden"], "login")
        type(emailA, into: need(app.textFields["E-Mail"], "email-feld"))
        type(passA, into: need(app.secureTextFields["Passwort (mind. 6 Zeichen)"], "passwort-feld"))
        app.buttons["Anmelden"].tap()
        need(app.buttons["Ziel suchen"], "karte", timeout: 60)
        for _ in 0..<4 { app.tap(); pause(3); dismissSystemDialogs() }
        shot("karte-nach-login")

        // Freund erscheint (Liste lädt alle 30 s)
        needPolling(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'von 1 sichtbar'")).firstMatch, "freund-sichtbar", timeout: 90)
        dismissSystemDialogs()
        pause(3)
        shot("freund-start")
        let before = distanceLabel()

        // B fährt nach Norden: sechs Positionen im 3-Sekunden-Takt
        var statuses: [Int] = []
        for _ in 0..<6 {
            lat += 0.0009                  // ~100 m je Schritt
            statuses.append(broadcast())
            pause(3)
        }
        XCTAssertTrue(statuses.allSatisfy { $0 < 300 }, "Broadcast von B angenommen: \(statuses)")
        shot("freund-nach-fahrt")
        let after = distanceLabel()
        XCTAssertNotNil(before); XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after, "Live-Position hat sich bewegt (\(before ?? "-") → \(after ?? "-"))")

        // Navigation: Route zum Düsseldorfer Hbf, Losfahren (Simulation)
        app.buttons["Ziel suchen"].tap()
        type("Düsseldorf Hauptbahnhof", into: need(app.textFields["Adresse oder Ort"], "suchfeld"))
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Hauptbahnhof'")).firstMatch
        need(result, "suchergebnis", timeout: 30).tap()
        need(app.buttons["Losfahren"], "route-vorschau", timeout: 40)
        pause(4)
        shot("route-vorschau")
        app.buttons["Losfahren"].tap()

        // Beobachten: Fehlerhinweis der App oder Navigationsansicht (Karte mit Suchleiste verschwindet)
        var shown = false
        for round in 0..<15 {
            pause(2)
            let err = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Navigation konnte'")).firstMatch
            if err.exists {
                shot("navigation-fehler")
                XCTFail("App meldet: \(err.label)")
                return
            }
            if round % 3 == 0 { shot("navigation-\(round)") }
            if !app.buttons["Ziel suchen"].exists { shown = true; break }
        }
        XCTAssertTrue(shown, "Navigationsansicht liegt über der Karte")
        pause(12)
        shot("navigation-a")
        pause(12)
        shot("navigation-b")
    }
}
