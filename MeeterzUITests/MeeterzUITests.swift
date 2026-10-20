import XCTest

/// Durchlauf für die CI: neues Testkonto registrieren, Onboarding, Karte, Suche, Freunde/Einstellungen,
/// Konto wieder löschen – mit Screenshots (SHOT_DIR). Die Zugangsdaten werden pro Lauf zufällig erzeugt.
class MeeterzTestBase: XCTestCase {
    var app: XCUIApplication!
    var counter = 0
    var shotPrefix: String { "ui" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ui.reset"]

        // Systemdialoge (Ortung, Mitteilungen) werden gezielt über dismissSystemDialogs() weggetippt
        app.launch()
    }

    // MARK: Hilfen

    func shot(_ name: String) {
        counter += 1
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = String(format: "%@/%@-%02d-%@.png", dir, shotPrefix, counter, name)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Wartet auf ein Element; fehlt es, gibt es einen Screenshot und der Test bricht ab.
    @discardableResult
    func need(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 20) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            shot("FEHLT-\(name)")
            XCTFail("Element nicht gefunden: \(name)")
        }
        return element
    }

    /// iOS blendet nach der Registrierung "Passwort sichern?" ein – wegtippen.
    func dismissSystemDialogs() {
        let spring = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Reihenfolge wichtig: Standort-Dialog („Allow While Using App“) vor „Don’t Allow“
        for label in ["Allow While Using App", "Beim Verwenden der App erlauben", "Allow Once", "Not Now", "Nicht jetzt", "Allow", "Keep Only While Using", "Nur beim Verwenden beibehalten", "Don’t Allow"] {
            let b = spring.buttons[label]
            if b.exists { b.tap(); pause(1) }
            let a = app.buttons[label]
            if a.exists { a.tap(); pause(1) }
        }
    }

    func type(_ text: String, into field: XCUIElement) {
        dismissSystemDialogs()
        // Fokus abwarten und bei Bedarf erneut tippen (Übergänge/Tastatur sind in CI träge)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for attempt in 0..<5 {
            dismissSystemDialogs()
            _ = field.waitForExistence(timeout: 10)
            if attempt % 2 == 0 { field.tap() }
            else { field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            let exp = XCTNSPredicateExpectation(predicate: focused, object: field)
            if XCTWaiter().wait(for: [exp], timeout: 4) == .completed { break }
        }
        if !focused.evaluate(with: field) {
            shot("kein-fokus")
        }
        field.typeText(text)
        // Prüfen, ob der Text wirklich im Feld steht (Systemdialoge können Eingaben verschlucken)
        for _ in 0..<(field.elementType == .secureTextField ? 0 : 2) {
            let current = (field.value as? String) ?? ""
            if current == text || field.value as? String == nil { break }
            pause(1)
            dismissSystemDialogs()
            field.tap()
            if !current.isEmpty && current != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            field.typeText(text)
        }
    }

    /// Wartet auf ein Element und tippt dabei zwischendurch Systemdialoge weg (kommen oft verspätet).
    @discardableResult
    func needPolling(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 75) -> XCUIElement {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists { return element }
            dismissSystemDialogs()
            _ = element.waitForExistence(timeout: 4)
        }
        return need(element, name, timeout: 1)
    }

    /// Ein Tipp auf die Karte blendet die Bedienelemente aus – vor Bedienung sicherstellen, dass sie da sind.
    func showChrome() {
        for _ in 0..<3 {
            let search = app.buttons["Ziel suchen"]
            if search.exists && search.isHittable { return }
            app.tap()
            pause(1)
        }
    }

    func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

final class MeeterzUITests: MeeterzTestBase {
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
        nameField.typeText("\n")        // Tastatur schließen, damit der nächste Fokus sauber wechselt
        pause(2)
        type(handle, into: need(app.textFields["@benutzername"], "onboarding-handle"))
        shot("onboarding")
        app.buttons["Los geht's"].tap()

        // 4. Karte
        need(app.buttons["Ziel suchen"], "karte", timeout: 40)
        app.tap()                       // löst ggf. Systemdialoge aus
        showChrome()
        pause(8)
        dismissSystemDialogs()
        pause(4)                       // Karte und Kacheln laden
        shot("karte")
        // Plus/Minus-Zoom (Flyover): zweimal heraus, Screenshot, wieder hinein
        let zoomOut = need(app.buttons["Herauszoomen"], "Herauszoomen-Knopf")
        zoomOut.tap(); zoomOut.tap()
        pause(3)
        shot("karte-herausgezoomt")
        app.buttons["Hineinzoomen"].tap(); app.buttons["Hineinzoomen"].tap()
        pause(2)

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
        showChrome()
        need(app.buttons["Freunde"], "freunde-knopf").tap()
        need(app.buttons.matching(NSPredicate(format: "label IN {'Freunde & Profil', 'Freunde hinzufügen'}")).firstMatch, "freunde-verwalten").tap()   // „Unterwegs“-Fenster → Verwaltung
        need(app.navigationBars["Profil"], "freunde-ansicht")
        shot("freunde-oben")

        let photoMenu = app.buttons["Foto hinzufügen"]
        if photoMenu.exists {
            photoMenu.tap()
            pause(1)
            shot("profilbild-menue")
            // Menü bzw. Fotoauswahl schließen (die Auswahl öffnet im Simulator direkt)
            pause(6)
            shot("profilbild-auswahl")
            var closed = false
            for label in ["Cancel", "Abbrechen", "Close", "Schließen"] {
                let b = app.buttons[label]
                if b.exists { b.tap(); closed = true; break }
            }
            if !closed { app.coordinate(withNormalizedOffset: CGVector(dx: 0.094, dy: 0.125)).tap() }
            pause(2)
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
