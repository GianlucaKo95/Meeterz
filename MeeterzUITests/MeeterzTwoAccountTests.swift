import XCTest
import UIKit

/// Zwei Konten: Konto A läuft in der App (Simulator), Konto B wird über die Backend-Schnittstelle gesteuert.
/// Geprüft: Freundschaftsanfrage → Annahme → Freund und Marker (mit Foto) auf der Karte →
/// Treffen-Einladung von B → Annahme in der App → Status bei B. Dazu Rechte-Prüfung mit einem fremden Konto C.
final class MeeterzTwoAccountTests: MeeterzTestBase {
    override var shotPrefix: String { "zk" }

    // MARK: Minimaler Backend-Client für B und C

    struct Remote {
        let base: String
        let key: String
        var token = ""
        var id = ""

        static func signUp(base: String, key: String, email: String, password: String) -> Remote? {
            var r = Remote(base: base, key: key)
            let (status, data) = r.request("POST", "/auth/v1/signup", body: ["email": email, "password": password], auth: false)
            guard status < 300, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = j["access_token"] as? String,
                  let u = j["user"] as? [String: Any], let id = u["id"] as? String else { return nil }
            r.token = t
            r.id = id.lowercased()
            return r
        }

        static func signIn(base: String, key: String, email: String, password: String) -> Remote? {
            var r = Remote(base: base, key: key)
            let (status, data) = r.request("POST", "/auth/v1/token?grant_type=password", body: ["email": email, "password": password], auth: false)
            guard status < 300, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = j["access_token"] as? String else { return nil }
            r.token = t
            return r
        }

        @discardableResult
        func request(_ method: String, _ path: String, body: Any? = nil, raw: Data? = nil,
                     headers: [String: String] = [:], auth: Bool = true) -> (Int, Data) {
            var req = URLRequest(url: URL(string: base + path)!)
            req.httpMethod = method
            req.setValue(key, forHTTPHeaderField: "apikey")
            req.setValue("Bearer " + (auth && !token.isEmpty ? token : key), forHTTPHeaderField: "Authorization")
            if let raw { req.httpBody = raw }
            else if let body {
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let sem = DispatchSemaphore(value: 0)
            var out: (Int, Data) = (0, Data())
            URLSession.shared.dataTask(with: req) { d, resp, _ in
                out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data())
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 30)
            return out
        }

        @discardableResult
        func rpc(_ name: String, _ body: [String: Any] = [:]) -> (Int, Any?) {
            let (s, d) = request("POST", "/rest/v1/rpc/\(name)", body: body)
            return (s, try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed))
        }
    }

    private func jpeg() -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        return r.jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor(red: 0.95, green: 0.4, blue: 0.2, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 78, y: 40, width: 100, height: 100))
            ctx.cgContext.fillEllipse(in: CGRect(x: 40, y: 150, width: 176, height: 140))
        }
    }

    // MARK: Ablauf

    func testZweiKonten() throws {
        let env = ProcessInfo.processInfo.environment
        let base = env["SB_URL"] ?? ""
        let key = env["SB_KEY"] ?? ""
        try XCTSkipIf(base.isEmpty || key.isEmpty, "SB_URL/SB_KEY fehlen")

        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let handleB = "cb_\(suffix)"
        let nameB = "Bea Beta"

        // Konto B vorbereiten: Profil, Standort in der Nähe (Duisburg), Profilfoto
        let b = try XCTUnwrap(Remote.signUp(base: base, key: key, email: "ci-b-\(suffix)@example.com", password: "Ci-b-\(suffix)-pw"), "Konto B anlegen")
        let (ps, _) = b.request("POST", "/rest/v1/profiles", body: ["id": b.id, "handle": handleB, "display_name": nameB],
                                headers: ["Prefer": "return=minimal"])
        XCTAssertLessThan(ps, 300, "Profil B anlegen")
        XCTAssertLessThan(b.rpc("update_last_location", ["lat": 51.4352, "lng": 6.7641, "heading": 90.0, "speed": 0.0]).0, 300, "Standort B")
        let (us, _) = b.request("POST", "/storage/v1/object/avatars/\(b.id)/avatar.jpg", raw: jpeg(),
                                headers: ["Content-Type": "image/jpeg", "x-upsert": "true"])
        XCTAssertLessThan(us, 300, "Foto B hochladen")
        XCTAssertLessThan(b.rpc("set_avatar_version").0, 300, "Fotoversion B")

        // Konto C (fremd, nie befreundet): darf Bild von B nicht lesen
        let c = try XCTUnwrap(Remote.signUp(base: base, key: key, email: "ci-c-\(suffix)@example.com", password: "Ci-c-\(suffix)-pw"), "Konto C anlegen")
        _ = c.request("POST", "/rest/v1/profiles", body: ["id": c.id, "handle": "cc_\(suffix)", "display_name": "Cem Fremd"], headers: ["Prefer": "return=minimal"])
        let (cs, _) = c.request("GET", "/storage/v1/object/authenticated/avatars/\(b.id)/avatar.jpg")
        XCTAssertGreaterThanOrEqual(cs, 400, "Fremder darf das Foto nicht laden (Status \(cs))")
        let (bs, _) = b.request("GET", "/storage/v1/object/authenticated/avatars/\(b.id)/avatar.jpg")
        XCTAssertEqual(bs, 200, "Besitzer lädt eigenes Foto")

        // Konto A in der App (wird am Ende in jedem Fall auch über das Backend entfernt)
        let email = "ci-a-\(suffix)@example.com"
        let password = "Ci-a-\(suffix)-pw"
        defer {
            // falls die App-Löschung nicht lief: A, B, C über das Backend aufräumen (Fehler egal)
            if let a = Remote.signIn(base: base, key: key, email: email, password: password) { a.rpc("delete_account") }
            b.rpc("delete_account")
            c.rpc("delete_account")
        }
        need(app.buttons["Registrieren"], "login")
        type(email, into: need(app.textFields["E-Mail"], "email-feld"))
        type(password, into: need(app.secureTextFields["Passwort (mind. 6 Zeichen)"], "passwort-feld"))
        app.buttons["Registrieren"].tap()
        let nameField = need(app.textFields["z. B. Luca"], "onboarding-name", timeout: 30)
        type("Al Alpha", into: nameField)
        nameField.typeText("\n")
        pause(2)
        type("ca_\(suffix)", into: need(app.textFields["@benutzername"], "onboarding-handle"))
        app.buttons["Los geht's"].tap()
        need(app.buttons["Ziel suchen"], "karte", timeout: 40)
        app.tap()
        if !app.buttons["Ziel suchen"].exists { app.tap() }   // Tipp auf die Karte blendet die Bedienelemente aus – wieder einblenden
        pause(6)
        dismissSystemDialogs()
        pause(3)
        shot("a-karte-ohne-freund")

        // A schickt B eine Anfrage
        need(app.buttons["Freunde"], "freunde-knopf").tap()
        need(app.buttons["Freunde verwalten"], "freunde-verwalten").tap()   // „Unterwegs“-Fenster → Verwaltung
        need(app.navigationBars["Freunde"], "freunde-ansicht")
        let addField = need(app.textFields["@benutzername"], "freund-feld")
        type(handleB, into: addField)
        addField.typeText("\n")
        app.buttons["Hinzufügen"].tap()
        pause(3)
        shot("a-anfrage-gesendet")

        // B nimmt an
        var requestId: String?
        for _ in 0..<10 where requestId == nil {
            if let rows = b.rpc("my_friends").1 as? [[String: Any]],
               let row = rows.first(where: { ($0["incoming"] as? Bool) == true }) {
                requestId = row["friendship_id"] as? String
            } else { pause(2) }
        }
        let rid = try XCTUnwrap(requestId, "Anfrage kam bei B an")
        XCTAssertLessThan(b.rpc("respond_friend_request", ["request_id": rid, "accept": true]).0, 300, "B nimmt an")

        // A sieht B in der Freundesliste (Aktualisierung alle 30 s)
        need(app.staticTexts[nameB], "freund-in-liste", timeout: 75)
        shot("a-freund-in-liste")

        // Sound-Pack (Backend): B lädt ein Schnipsel hoch; A (Freund) sieht und lädt es, C (fremd) nicht
        let clip = Data(repeating: 0x41, count: 4096)
        let (su, _) = b.request("POST", "/storage/v1/object/sounds/\(b.id)/pass.m4a", raw: clip,
                                headers: ["Content-Type": "audio/mp4", "x-upsert": "true"])
        XCTAssertLessThan(su, 300, "Schnipsel von B hochladen (Status \(su))")
        XCTAssertLessThan(b.rpc("set_sound", ["p_moment": "pass"]).0, 300, "Schnipsel-Version von B")
        if let aRemote = Remote.signIn(base: base, key: key, email: email, password: password) {
            let sounds = aRemote.rpc("friend_sounds").1 as? [[String: Any]]
            XCTAssertTrue(sounds?.contains { ($0["user_id"] as? String) == b.id && ($0["moment"] as? String) == "pass" } ?? false,
                          "A sieht das Schnipsel von B")
            let (ad, _) = aRemote.request("GET", "/storage/v1/object/authenticated/sounds/\(b.id)/pass.m4a")
            XCTAssertEqual(ad, 200, "A darf das Schnipsel von B laden")
        } else { XCTFail("A per Backend anmelden") }
        let cSounds = c.rpc("friend_sounds").1 as? [[String: Any]]
        XCTAssertFalse(cSounds?.contains { ($0["user_id"] as? String) == b.id } ?? false, "C sieht keine Schnipsel von B")
        let (cd, _) = c.request("GET", "/storage/v1/object/authenticated/sounds/\(b.id)/pass.m4a")
        XCTAssertGreaterThanOrEqual(cd, 400, "C darf das Schnipsel von B nicht laden (Status \(cd))")

        // Zurück zur Karte: Marker mit Foto von B
        app.buttons["Fertig"].tap()
        dismissSystemDialogs()
        // Der Freund zählt erst als angenommen und sichtbar, wenn die Karte ihn geladen hat
        if !app.buttons["Freunde"].exists { app.tap() }      // Bedienelemente ggf. wieder einblenden
        need(app.buttons["Freunde"], "freunde-knopf-sichtbar").tap()          // „Unterwegs“-Fenster
        needPolling(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'von 1 sichtbar'")).firstMatch,
                    "freund-sichtbar", timeout: 75)
        app.buttons["Fertig"].tap()
        pause(1)
        pause(5)
        dismissSystemDialogs()
        shot("a-karte-mit-freund")

        // ── Inkognito: A wird für B unsichtbar (Standort + Route), B-Routen lassen sich verbergen ──
        let aRemote = try XCTUnwrap(Remote.signIn(base: base, key: key, email: email, password: password), "A per Backend anmelden")
        XCTAssertLessThan(aRemote.rpc("update_last_location", ["lat": 51.4356, "lng": 6.7645, "heading": 0.0, "speed": 0.0]).0, 300, "Standort A")
        func locationOfA(seenBy r: Remote) -> Bool {
            ((r.rpc("my_friends").1 as? [[String: Any]])?.first?["lat"] as? Double) != nil
        }
        func waitFor(_ expected: Bool, _ what: String, _ check: () -> Bool) {
            for _ in 0..<10 where check() != expected { pause(1.5) }
            XCTAssertEqual(check(), expected, what)
        }
        waitFor(true, "B sieht A vor Inkognito") { locationOfA(seenBy: b) }

        need(app.buttons["Inkognito-Modus aktivieren"], "inkognito-knopf").tap()
        need(app.buttons["1 Stunde"], "inkognito-dauer").tap()
        pause(3)
        shot("a-inkognito")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Inkognito'")).firstMatch.waitForExistence(timeout: 10),
                      "Inkognito-Hinweis auf der Karte")
        waitFor(false, "B sieht A im Inkognito nicht") { locationOfA(seenBy: b) }

        need(app.buttons["Inkognito-Modus beenden"], "inkognito-beenden").tap()
        pause(3)
        waitFor(true, "B sieht A nach Inkognito wieder") { locationOfA(seenBy: b) }

        // Routen verbergen: B teilt eine Route, A sieht sie; mit hide_routes nicht mehr
        let t = Date().timeIntervalSince1970
        let routeBody: [String: Any] = [
            "destination_name": "Ziel", "dest_lat": 51.45, "dest_lng": 6.78, "eta_unix": t + 1800,
            "points": [[6.7641, 51.4352, t], [6.77, 51.44, t + 300], [6.78, 51.45, t + 900]],
        ]
        XCTAssertLessThan(b.rpc("set_active_route", routeBody).0, 300, "B teilt Route")
        func routesSeenByA() -> Int { (aRemote.rpc("friends_routes").1 as? [[String: Any]])?.count ?? -1 }
        waitFor(true, "A sieht Route von B") { routesSeenByA() == 1 }
        XCTAssertLessThan(b.request("PATCH", "/rest/v1/profiles?id=eq.\(b.id)", body: ["hide_routes": true], headers: ["Prefer": "return=minimal"]).0, 300, "B verbirgt Routen")
        waitFor(true, "A sieht Route von B nicht mehr") { routesSeenByA() == 0 }
        _ = b.request("PATCH", "/rest/v1/profiles?id=eq.\(b.id)", body: ["hide_routes": false], headers: ["Prefer": "return=minimal"])
        _ = b.rpc("clear_active_route")

        // B lädt A zu einem Treffen ein
        let myId = try XCTUnwrap((b.rpc("my_friends").1 as? [[String: Any]])?.first?["friend_id"] as? String, "A-ID")
        let (pm, meetId) = b.rpc("propose_meetup", ["to_user_id": myId, "place_name": "Café Test", "lat": 51.4360, "lng": 6.7650])
        XCTAssertLessThan(pm, 300, "B schlägt Treffen vor")
        needPolling(app.buttons["Annehmen"], "einladung-sichtbar", timeout: 60)
        shot("a-einladung")
        app.buttons["Annehmen"].tap()
        pause(4)
        shot("a-nach-annahme")

        // Status bei B
        var accepted = false
        for _ in 0..<8 where !accepted {
            if let rows = b.rpc("my_meetups").1 as? [[String: Any]],
               rows.contains(where: { ($0["status"] as? String) == "accepted" }) { accepted = true } else { pause(2) }
        }
        XCTAssertTrue(accepted, "B sieht das Treffen als angenommen (\(String(describing: meetId)))")

        // Aufräumen: A über die App, B und C über das Backend
        for _ in 0..<3 where !app.navigationBars["Freunde"].exists {
            need(app.buttons["Freunde"], "freunde-knopf-2").tap()
            if app.buttons["Freunde verwalten"].waitForExistence(timeout: 6) { app.buttons["Freunde verwalten"].tap() }
            _ = app.navigationBars["Freunde"].waitForExistence(timeout: 6)
        }
        need(app.navigationBars["Freunde"], "freunde-ansicht-2")
        pause(2)
        let list = app.tables.firstMatch.exists ? app.tables.firstMatch : app.collectionViews.firstMatch
        for _ in 0..<6 where !app.buttons["Konto löschen"].exists { list.swipeUp() }
        need(app.buttons["Konto löschen"], "konto-loeschen").tap()
        need(app.buttons["Konto und alle Daten löschen"], "loeschen-bestaetigen").tap()
        need(app.buttons["Anmelden"], "login-nach-loeschen", timeout: 30)
        shot("a-nach-loeschen")
        b.rpc("delete_account")
        c.rpc("delete_account")
    }
}
