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
        app.launchArguments += ["-ui.reset", "-dev.simulate", "YES"] + Self.german   // Satellit ist Standard; kein Argument, sonst überschreibt es den Umschalter
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
        let suffix = "fix"
        let emailA = MeeterzTwoAccountTests.Remote.email("na"), passA = MeeterzTwoAccountTests.Remote.testPassword

        // A und B anlegen, befreunden, B in der Nähe platzieren
        let a = try XCTUnwrap(MeeterzTwoAccountTests.Remote.fixed("na", base: base, key: key), "Konto A")
        let b = try XCTUnwrap(MeeterzTwoAccountTests.Remote.fixed("nb", base: base, key: key), "Konto B")
        let hp: [String: String] = ["Prefer": "return=minimal"]
        a.request("POST", "/rest/v1/profiles", body: ["id": a.id, "handle": "na_\(suffix)", "display_name": "Al Alpha"], headers: hp)
        b.request("POST", "/rest/v1/profiles", body: ["id": b.id, "handle": "nb_\(suffix)", "display_name": "Bea Beta"], headers: hp)
        // Zweiter Freund C: muss neben B ebenfalls auf der Karte erscheinen
        let c = try XCTUnwrap(MeeterzTwoAccountTests.Remote.fixed("nc", base: base, key: key), "Konto C")
        c.request("POST", "/rest/v1/profiles", body: ["id": c.id, "handle": "nc_\(suffix)", "display_name": "Cleo Gamma"], headers: hp)
        // Konten bleiben bestehen und werden beim nächsten Lauf zurückgesetzt
        a.rpc("send_friend_request", ["target_handle": "nb_\(suffix)"])
        let rows = try XCTUnwrap(b.rpc("my_friends").1 as? [[String: Any]])
        let rid = try XCTUnwrap(rows.first?["friendship_id"] as? String)
        XCTAssertLessThan(b.rpc("respond_friend_request", ["request_id": rid, "accept": true]).0, 300)
        a.rpc("send_friend_request", ["target_handle": "nc_\(suffix)"])
        let rowsC = try XCTUnwrap(c.rpc("my_friends").1 as? [[String: Any]])
        let ridC = try XCTUnwrap(rowsC.first?["friendship_id"] as? String)
        XCTAssertLessThan(c.rpc("respond_friend_request", ["request_id": ridC, "accept": true]).0, 300)
        // C steht ~11 m neben A (Simulator-Standort 51.4344, 6.7623): muss trotzdem als Marker sichtbar sein
        c.rpc("update_last_location", ["lat": 51.4345, "lng": 6.7624, "heading": 90.0, "speed": 0.0])

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
        for _ in 0..<4 { tapMap(); pause(3); dismissSystemDialogs() }
        showChrome()
        shot("karte-nach-login")

        // Freund erscheint (Liste lädt alle 30 s)
        showChrome()
        need(app.buttons["Freunde"], "freunde-knopf").tap()      // „Unterwegs“-Fenster bleibt für die Messung offen
        pause(2)
        if !app.buttons["Fertig"].exists {
            // Diagnose: Tipp kam nicht an?
            shot("unterwegs-nicht-offen-hittable-\(app.buttons["Freunde"].isHittable)")
            app.buttons["Freunde"].tap(); pause(2)
        }
        shot("unterwegs-offen")
        needPolling(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '2 von 2 sichtbar'")).firstMatch, "beide-freunde-sichtbar", timeout: 90)
        XCTAssertTrue(app.staticTexts["Bea Beta"].exists, "Freund B in der Liste")
        XCTAssertTrue(app.staticTexts["Cleo Gamma"].exists, "Freund C in der Liste")
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
        app.buttons["Fertig"].tap()
        pause(4)
        shot("karte-mit-nahem-freund")
        // Dasselbe auf der klassischen (Mapbox-)Karte: umschalten, bis der Knopf den Wechsel bestätigt
        for _ in 0..<4 {
            showChrome()
            let menu = app.buttons["Kartenansicht"]
            if menu.waitForExistence(timeout: 5) { menu.tap() }
            let toClassic = app.buttons["Klassische Karte"]
            if toClassic.waitForExistence(timeout: 3) { toClassic.tap() }
            pause(3)
            if (app.buttons["Kartenansicht"].value as? String)?.hasPrefix("Klassisch") == true { break }
        }
        pause(8)
        shot("karte-klassisch-naher-freund")

        // Navigation: Route zum Düsseldorfer Hbf, Losfahren (Simulation)
        app.buttons["Ziel suchen"].tap()
        type("Düsseldorf Hauptbahnhof", into: need(app.textFields["Adresse oder Ort"], "suchfeld"))
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Hauptbahnhof'")).firstMatch
        need(result, "suchergebnis", timeout: 30).tap()
        need(app.buttons["Losfahren"], "route-vorschau", timeout: 40)
        pause(4)
        shot("route-vorschau")
        // Fortbewegungsart wechseln: zu Fuß, dann Fahrrad, zurück zum Auto
        for (name, label) in [("Zu Fuß", "zu-fuss"), ("Fahrrad", "fahrrad"), ("Auto", "auto")] {
            let b = need(app.buttons["Fortbewegungsart \(name)"], "modus-\(label)")
            b.tap()
            pause(8)
            shot("route-vorschau-\(label)")
        }
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
