import XCTest
import MapKit

/// App-Store-Screenshots mit erfundenen Daten. Läuft nur, wenn SHOT_LANG gesetzt ist (ci/storeshots.sh).
/// Feste Testkonten bekommen je Sprache erfundene, landestypische Namen und eine eigene Stadt (Köln, New York, Paris,
/// Madrid, Lissabon, Istanbul, Rom); zwei Freunde teilen eine Route (echte Straßen über MapKit). Die App läuft in der gewünschten Sprache; Knöpfe werden über die
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
        dismissSystemDialogs()
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

    /// Erstes sichtbares, antippbares Element mit diesem Text (verdeckte Freunde-Marker hinter Fenstern sind nicht antippbar)
    func hittable(_ query: XCUIElementQuery, containing text: String, timeout: TimeInterval = 20) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let all = query.matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
            // Erster Treffer von oben (beim Suchergebnis die Zeile selbst, nicht ihr ⓘ-Knopf)
            if let e = all.first(where: { $0.exists && $0.isHittable && $0.frame.minY > 100 }) { return e }
            pause(1)
        }
        return nil
    }

    /// Gruppen-Treffen: Zeile eines Freundes antippen. Die Namen stehen auch im Unterwegs-Fenster darunter – darum
    /// den Namen direkt unter der Überschrift „Wer kommt mit?“ nehmen und links auf den Auswahlkreis tippen.
    func tapGroupRow(_ name: String) -> Bool {
        let header = app.staticTexts[L("Wer kommt mit?")]
        guard header.waitForExistence(timeout: 10) else { return false }
        let top = header.frame.maxY
        let texts = app.staticTexts.matching(NSPredicate(format: "label == %@", name)).allElementsBoundByIndex
        guard let row = texts.filter({ $0.exists && $0.frame.minY > top }).min(by: { $0.frame.minY < $1.frame.minY }) else { return false }
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: row.frame.midY))
        point.tap()
        return true
    }

    /// Karte auf den eigenen (erfundenen) Standort zentrieren
    func centerOnMe() {
        chrome()
        let b = app.buttons[L("Auf meinen Standort zentrieren")]
        if b.waitForExistence(timeout: 5) { b.tap() } else { shot("FEHLT-zentrieren") }
    }

    // MARK: Erfundene Route über echte Straßen

    /// Punkte wie in der App: [lng, lat, eta_unix] – die Ankunftszeit je Punkt braucht das Backend (route_points)
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> (points: [[Double]], seconds: Double) {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = .automobile
        var coords = [from, to]
        var seconds = 900.0
        let done = expectation(description: "Route")
        MKDirections(request: req).calculate { resp, _ in
            if let r = resp?.routes.first {
                let n = r.polyline.pointCount
                var all = [CLLocationCoordinate2D](repeating: .init(), count: n)
                r.polyline.getCoordinates(&all, range: NSRange(location: 0, length: n))
                let step = max(1, n / 120)
                coords = stride(from: 0, to: n, by: step).map { all[$0] }
                if let last = all.last { coords.append(last) }
                seconds = r.expectedTravelTime
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        // Ankunft je Punkt anteilig zur Strecke
        var dist = [0.0]
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            dist.append(dist[i - 1] + a.distance(from: b))
        }
        let total = max(dist.last ?? 1, 1), now = Date().timeIntervalSince1970
        let points = coords.enumerated().map { i, c in [c.longitude, c.latitude, now + seconds * dist[i] / total] }
        return (points, seconds)
    }

    // MARK: Schauplätze je Sprache (Simulator-Standort setzt ci/storeshots.sh auf `center`)

    struct Friend { let name: String; let at: CLLocationCoordinate2D; let heading: Double; let driving: Bool }
    struct Scenario { let me: String; let friends: [Friend]; let dest: CLLocationCoordinate2D; let destName: String; let search: String; let match: String }

    static func scenario(_ lang: String) -> Scenario {
        func c(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
        switch lang {
        case "en": return Scenario(me: "Ethan", friends: [
                Friend(name: "Emma", at: c(40.7794, -73.9632), heading: 200, driving: true),
                Friend(name: "Jack", at: c(40.7306, -73.9866), heading: 260, driving: true),
                Friend(name: "Sophie", at: c(40.7614, -73.9776), heading: 0, driving: false)],
            dest: c(40.7424, -74.0060), destName: "Chelsea Market", search: "Chelsea Market New York", match: "Chelsea Market")
        case "fr": return Scenario(me: "Hugo", friends: [
                Friend(name: "Léa", at: c(48.8738, 2.2950), heading: 100, driving: true),
                Friend(name: "Lucas", at: c(48.8420, 2.3210), heading: 40, driving: true),
                Friend(name: "Chloé", at: c(48.8530, 2.3499), heading: 0, driving: false)],
            dest: c(48.8710, 2.3650), destName: "Canal Saint-Martin", search: "Canal Saint-Martin Paris", match: "Saint-Martin")
        case "es": return Scenario(me: "Pablo", friends: [
                Friend(name: "Lucía", at: c(40.4300, -3.6800), heading: 200, driving: true),
                Friend(name: "Mateo", at: c(40.3920, -3.6980), heading: 20, driving: true),
                Friend(name: "Sofía", at: c(40.4233, -3.7122), heading: 0, driving: false)],
            dest: c(40.4138, -3.6921), destName: "Museo del Prado", search: "Museo del Prado", match: "Prado")
        case "pt": return Scenario(me: "Tiago", friends: [
                Friend(name: "Beatriz", at: c(38.7369, -9.1427), heading: 220, driving: true),
                Friend(name: "Rodrigo", at: c(38.7253, -9.1500), heading: 230, driving: true),
                Friend(name: "Inês", at: c(38.7114, -9.1300), heading: 0, driving: false)],
            dest: c(38.7635, -9.0937), destName: "Oceanário de Lisboa", search: "Oceanário de Lisboa", match: "Oceanário")
        case "tr": return Scenario(me: "Emre", friends: [
                Friend(name: "Elif", at: c(41.0600, 28.9870), heading: 120, driving: true),
                Friend(name: "Burak", at: c(41.0256, 28.9742), heading: 60, driving: true),
                Friend(name: "Zeynep", at: c(41.0330, 28.9930), heading: 0, driving: false)],
            dest: c(41.0475, 29.0270), destName: "Ortaköy", search: "Ortaköy İstanbul", match: "Ortaköy")
        case "it": return Scenario(me: "Marco", friends: [
                Friend(name: "Giulia", at: c(41.9010, 12.5010), heading: 240, driving: true),
                Friend(name: "Alessandro", at: c(41.9070, 12.4590), heading: 170, driving: true),
                Friend(name: "Sofia", at: c(41.8902, 12.4922), heading: 0, driving: false)],
            dest: c(41.8894, 12.4703), destName: "Trastevere", search: "Piazza di Santa Maria in Trastevere Roma", match: "Trastevere")
        default: return Scenario(me: "Jonas", friends: [
                Friend(name: "Anna", at: c(50.9338, 6.9302), heading: 110, driving: true),
                Friend(name: "Ben", at: c(50.9531, 6.9852), heading: 200, driving: true),
                Friend(name: "Mia", at: c(50.9478, 6.9411), heading: 0, driving: false)],
            dest: c(50.9262, 6.9653), destName: "Rheinauhafen", search: "Rheinauhafen Köln", match: "Rheinauhafen")
        }
    }

    // MARK: Ablauf

    func testStoreScreenshots() throws {
        let env = ProcessInfo.processInfo.environment
        let base = env["SB_URL"] ?? "", key = env["SB_KEY"] ?? ""
        try XCTSkipIf(base.isEmpty || key.isEmpty, "SB_URL/SB_KEY fehlen")
        let hp = ["Prefer": "return=minimal"]

        // Ich (in der App) und drei erfundene Freunde – je Sprache eine eigene Stadt mit passenden Namen
        let sc = Self.scenario(lang)
        let me = try XCTUnwrap(Remote.fixed("shot-me", base: base, key: key), "Konto Ich")
        me.request("POST", "/rest/v1/profiles", body: ["id": me.id, "handle": "me_demo", "display_name": sc.me], headers: hp)
        for (i, p) in sc.friends.enumerated() {
            let r = try XCTUnwrap(Remote.fixed("shot-\(i + 1)", base: base, key: key), "Konto \(p.name)")
            let handle = "friend\(i + 1)_demo"
            r.request("POST", "/rest/v1/profiles", body: ["id": r.id, "handle": handle, "display_name": p.name], headers: hp)
            me.rpc("send_friend_request", ["target_handle": handle])
            let rows = try XCTUnwrap(r.rpc("my_friends").1 as? [[String: Any]])
            if let rid = rows.first?["friendship_id"] as? String {
                r.rpc("respond_friend_request", ["request_id": rid, "accept": true])
            }
            r.rpc("update_last_location", ["lat": p.at.latitude, "lng": p.at.longitude, "heading": p.heading, "speed": p.driving ? 9.0 : 0.0])
            if p.driving {
                let rt = route(from: p.at, to: sc.dest)
                let (status, body) = r.rpc("set_active_route", ["destination_name": sc.destName, "dest_lat": sc.dest.latitude, "dest_lng": sc.dest.longitude,
                                          "eta_unix": Date().timeIntervalSince1970 + rt.seconds, "points": rt.points, "travel_mode": "car"])
                XCTAssertLessThan(status, 300, "Route von \(p.name) teilen: \(String(describing: body))")
            }
        }

        let accepted = (me.rpc("my_friends").1 as? [[String: Any]] ?? []).filter { ($0["status"] as? String) == "accepted" }.count
        XCTAssertEqual(accepted, sc.friends.count, "alle erfundenen Freunde angenommen")

        // Anmelden
        need(app.buttons[L("Anmelden")], "login")
        type(Remote.email("shot-me"), into: need(app.textFields[L("E-Mail")], "email-feld"))
        type(Remote.testPassword, into: need(app.secureTextFields[L("Passwort (mind. 6 Zeichen)")], "passwort-feld"))
        app.buttons[L("Anmelden")].tap()
        need(app.buttons[L("Ziel suchen")], "karte", timeout: 60)
        for _ in 0..<3 { tapMap(); pause(3); dismissSystemDialogs() }
        chrome()
        // Warten, bis die erfundenen Freunde auf der Karte stehen (erster Lauf im frischen Simulator ist langsam)
        let firstFriend = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", sc.friends[0].name)).firstMatch
        if !firstFriend.waitForExistence(timeout: 90) { shot("FEHLT-freunde-auf-karte") }
        pause(15)    // Routen und Kartenkacheln laden
        // Hinweis „Nur bei offener App sichtbar“ (Simulator hat keine „Immer“-Freigabe) ausblenden
        for label in ["Hinweis ausblenden", "Hinweis schließen"] {
            let x = app.buttons[L(label)]
            if x.exists { x.tap(); pause(1) }
        }
        centerOnMe()
        pause(4)
        // Herauszoomen, bis die Freunde und ihre Routen ins Bild passen (~2 km Umkreis)
        let map = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        for _ in 0..<3 {
            app.pinch(withScale: 0.4, velocity: -1.5)
            pause(2)
        }
        _ = map
        pause(10)    // Kacheln zeichnen

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
            for name in sc.friends.map(\.name) {
                // Nur sichtbare Zeilen der Liste – nicht die gleichnamigen Freunde-Marker auf der Karte dahinter
                if tapGroupRow(name) { pause(1) } else { shot("FEHLT-gruppe-\(name)") }
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
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap(); pause(2)   // Menü schließen (unten auf die Karte)
        }

        // 5 Navigation (simulierte Fahrt) zum Ziel des Schauplatzes
        chrome()
        app.buttons[L("Ziel suchen")].tap()
        type(sc.search, into: need(app.textFields[L("Adresse oder Ort")], "suchfeld"))
        // Nur sichtbare Suchtreffer – nicht die Freunde-Marker hinter dem Suchfenster, deren Text das Ziel nennt
        guard let hit = hittable(app.buttons, containing: sc.match, timeout: 30) else {
            shot("FEHLT-suchergebnis"); XCTFail("Suchtreffer \(sc.match)"); return
        }
        hit.tap()
        need(app.buttons[L("Losfahren")], "route-vorschau", timeout: 40)
        pause(5)
        storeShot(6, "routenvorschau")
        app.buttons[L("Losfahren")].tap()
        pause(30)
        storeShot(7, "navigation-a")   // Reserve, falls die erste Aufnahme Kacheln vermisst
        pause(15)
        storeShot(5, "navigation")
    }
}
