import XCTest

/// Durchlauf für die CI: neues Testkonto registrieren, Onboarding, Karte, Suche, Freunde/Einstellungen,
/// Konto wieder löschen – mit Screenshots (SHOT_DIR). Die Zugangsdaten werden pro Lauf zufällig erzeugt.
final class MeeterzUITests: XCTestCase {
    private var app: XCUIApplication!
    private var counter = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()

        // Systemdialoge (Ortung, Mitteilungen) wegklicken
        addUIInterruptionMonitor(withDescription: "Systemdialog") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow", "OK", "Beim Verwenden der App erlauben", "Erlauben"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        app.launch()
    }

    // MARK: Hilfen

    private func shot(_ name: String) {
        counter += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = String(format: "%@/ui-%02d-%@.png", dir, counter, name)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Wartet auf ein Element; fehlt es, gibt es einen Screenshot und der Test bricht ab.
    @discardableResult
    private func need(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 20) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            shot("FEHLT-\(name)")
            XCTFail("Element nicht gefunden: \(name)")
        }
        return element
    }

    private func type(_ text: String, into field: XCUIElement) {
        // Fokus abwarten und bei Bedarf erneut tippen (Übergänge/Tastatur sind in CI träge)
        for _ in 0..<4 {
            if field.waitForExistence(timeout: 10), field.isHittable { field.tap() }
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) { pause(0.5); break }
            pause(1)
        }
        field.typeText(text)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: Ablauf

    func testGesamtablauf() throws {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let email = "ci-\(suffix)@example.com"
        let password = "Ci-\(suffix)-pw"
        let handle = "ci_\(suffix)"

        // 1. Login-Bildschirm
        need(app.buttons["Registrieren"], "login")
        shot("login")

        // 2. Registrieren
        type(email, into: need(app.textFields["E-Mail"], "email-feld"))
        type(password, into: need(app.secureTextFields["Passwort (mind. 6 Zeichen)"], "passwort-feld"))
        shot("login-ausgefuellt")
        app.buttons["Registrieren"].tap()

        // 3. Onboarding
        let nameField = need(app.textFields["z. B. Luca"], "onboarding-name", timeout: 30)
        type("CI Test", into: nameField)
        type(handle, into: need(app.textFields["@benutzername"], "onboarding-handle"))
        shot("onboarding")
        app.buttons["Los geht's"].tap()

        // 4. Karte
        need(app.buttons["Ziel suchen"], "karte", timeout: 40)
        app.tap()                       // löst ggf. Systemdialoge aus
        pause(10)                       // Karte und Kacheln laden
        shot("karte")

        let toClassic = app.buttons["Zur klassischen Karte wechseln"]
        if toClassic.exists {
            toClassic.tap()
            pause(5)
            shot("karte-klassisch")
        }
        let to2D = app.buttons["Zur 2D-Ansicht wechseln"]
        if to2D.exists {
            to2D.tap()
            pause(4)
            shot("karte-2d")
        }

        // 5. Zielsuche
        app.buttons["Ziel suchen"].tap()
        let searchField = need(app.textFields["Adresse oder Ort"], "suchfeld")
        type("Düsseldorf Hauptbahnhof", into: searchField)
        pause(6)
        shot("suche")
        app.swipeDown(velocity: .fast)

        // 6. Freunde und Einstellungen
        need(app.buttons["Freunde"], "freunde-knopf").tap()
        need(app.navigationBars["Freunde"], "freunde-ansicht")
        shot("freunde-oben")

        let photoMenu = app.buttons["Foto hinzufügen"]
        if photoMenu.exists {
            photoMenu.tap()
            pause(1)
            shot("profilbild-menue")
            // Menü schließen
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.05)).tap()
            pause(1)
        }

        let list = app.tables.firstMatch.exists ? app.tables.firstMatch : app.collectionViews.firstMatch
        list.swipeUp()
        shot("einstellungen-mitte")
        list.swipeUp()
        shot("einstellungen-unten")

        // 7. Konto löschen (räumt das Testkonto auf)
        let deleteButton = need(app.buttons["Konto löschen"], "konto-loeschen")
        deleteButton.tap()
        shot("loeschen-dialog")
        need(app.buttons["Konto und alle Daten löschen"], "loeschen-bestaetigen").tap()

        // 8. Zurück beim Login
        need(app.buttons["Anmelden"], "login-nach-loeschen", timeout: 30)
        shot("nach-loeschen")
    }
}
