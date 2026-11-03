import Foundation
import CarPlay

/// Einziger Weg für Ansichtswechsel und Hinweise in CarPlay.
///
/// CarPlay verträgt keine überlappenden Wechsel: Ein `push` während eines laufenden `pop`, ein `present`
/// über einer schon gezeigten Auswahl oder ein Hinweis auf einer Karte, die Mapbox gerade gegen die
/// Navigationsansicht tauscht, lässt die große Ansicht stehen (oder wirft eine Ausnahme), während das Dashboard
/// weiterläuft. Darum laufen alle Wechsel hier nacheinander: der nächste erst, wenn CarPlay den vorigen bestätigt hat.
/// Fehler meldet CarPlay in der Bestätigung – die landen im Diagnose-Log.
@MainActor
final class CarPlayUI {
    static let shared = CarPlayUI()

    /// CarPlay erlaubt Navigations-Apps höchstens 5 Ebenen (Karte + 4); darüber gibt es eine Ausnahme
    private static let maxDepth = 5

    private var queue: [(name: String, run: (@escaping () -> Void) -> Void)] = []
    private var busy = false
    /// Karte, auf der unser letzter Hinweis liegt – wird beim Wechsel der Navigationsansicht weggeräumt
    private weak var alertHost: CPMapTemplate?

    private var controller: CPInterfaceController? { CarPlayController.shared.manager.interfaceController }

    // MARK: Ansichten

    func push(_ template: CPTemplate, animated: Bool = true) {
        enqueue("push \(type(of: template))") { c, done in
            if c.presentedTemplate != nil {
                c.dismissTemplate(animated: false) { _, _ in }
            }
            guard c.templates.count < Self.maxDepth else {
                Diag.log("CarPlay: Ansicht nicht geöffnet – schon \(c.templates.count) Ebenen")
                return done(nil)
            }
            guard !c.templates.contains(where: { $0 === template }) else { return done(nil) }
            c.pushTemplate(template, animated: animated) { _, e in done(e) }
        }
    }

    func pop(animated: Bool = true) {
        enqueue("pop") { c, done in
            guard c.templates.count > 1 else { return done(nil) }
            c.popTemplate(animated: animated) { _, e in done(e) }
        }
    }

    func popToRoot(animated: Bool = true) {
        enqueue("popToRoot") { c, done in
            if c.presentedTemplate != nil { c.dismissTemplate(animated: false) { _, _ in } }
            guard c.templates.count > 1 else { return done(nil) }
            c.popToRootTemplate(animated: animated) { _, e in done(e) }
        }
    }

    /// Auswahl/Rückfrage (Action Sheet, Alert). Eine schon offene wird vorher geschlossen.
    func present(_ template: CPTemplate, animated: Bool = true) {
        enqueue("present \(type(of: template))") { c, done in
            if c.presentedTemplate != nil {
                c.dismissTemplate(animated: false) { _, _ in
                    c.presentTemplate(template, animated: animated) { _, e in done(e) }
                }
            } else {
                c.presentTemplate(template, animated: animated) { _, e in done(e) }
            }
        }
    }

    func dismiss(animated: Bool = true) {
        enqueue("dismiss") { c, done in
            guard c.presentedTemplate != nil else { return done(nil) }
            c.dismissTemplate(animated: animated) { _, e in done(e) }
        }
    }

    // MARK: Hinweise über der Karte

    /// Wichtigkeit eines Hinweises: Es steht immer nur einer auf der Karte. Ein wichtigerer ersetzt einen weniger
    /// wichtigen; sonst wartet er (höchstens eine Minute) und kommt mit kurzem Abstand danach – statt dass Baustelle,
    /// Ladeplan und Vorschlag direkt hintereinander aufpoppen.
    enum AlertPriority: Int, Comparable {
        case low, normal, high
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    private var shownPriority: AlertPriority = .normal
    private var pending: [(alert: CPNavigationAlert, priority: AlertPriority, until: Date)] = []
    private var pendingTimer: Timer?
    private var lastAlertGone = Date.distantPast

    /// Hinweis auf der Karte – nur, wenn sie ganz oben liegt und gerade kein Wechsel läuft. Gibt zurück, ob er
    /// erschien oder zum Nachreichen vorgemerkt ist.
    @discardableResult
    func alert(_ alert: CPNavigationAlert, replacing: Bool = false, priority: AlertPriority = .normal) -> Bool {
        guard let template = CarPlayController.shared.alertTemplate else { return false }
        let title = alert.titleVariants.first ?? ""
        if busy || !queue.isEmpty || (template.currentNavigationAlert != nil && !replacing && priority <= shownPriority) {
            // Später zeigen (gleicher Titel nur einmal vormerken)
            pending.removeAll { ($0.alert.titleVariants.first ?? "") == title }
            pending.append((alert, priority, Date().addingTimeInterval(60)))
            pending.sort { $0.priority > $1.priority }
            if pending.count > 3 { pending.removeLast(pending.count - 3) }
            startPendingTimer()
            return true
        }
        if template.currentNavigationAlert != nil {
            template.dismissNavigationAlert(animated: false) { _ in }
        }
        alertHost = template
        shownPriority = priority
        StallLogger.shared.note("Hinweis \(title)")
        template.present(navigationAlert: alert, animated: true)
        return true
    }

    /// Wartende Hinweise nachreichen, sobald die Karte frei ist (mit 3 s Abstand zum vorigen)
    private func startPendingTimer() {
        guard pendingTimer == nil else { return }
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { CarPlayUI.shared.showPendingIfFree() }
        }
    }

    private func showPendingIfFree() {
        pending.removeAll { $0.until < Date() }
        guard !pending.isEmpty, let template = CarPlayController.shared.alertTemplate else {
            if pending.isEmpty { pendingTimer?.invalidate(); pendingTimer = nil }
            return
        }
        if template.currentNavigationAlert != nil { lastAlertGone = Date(); return }
        guard Date().timeIntervalSince(lastAlertGone) > 3, !busy, queue.isEmpty else { return }
        let next = pending.removeFirst()
        alertHost = template
        shownPriority = next.priority
        StallLogger.shared.note("Hinweis (nachgereicht) \(next.alert.titleVariants.first ?? "")")
        template.present(navigationAlert: next.alert, animated: true)
        lastAlertGone = Date()
    }

    /// Vor einem Wechsel der Navigationsansicht (Start/Ende der Navigation): offenen Hinweis wegräumen,
    /// damit er nicht auf einer Karte hängen bleibt, die CarPlay gleich ersetzt.
    func clearAlerts() {
        if let host = alertHost, host.currentNavigationAlert != nil {
            host.dismissNavigationAlert(animated: false) { _ in }
        }
        alertHost = nil
    }

    /// Beim Trennen von CarPlay: nichts Altes nachholen
    func reset() {
        pending = []
        pendingTimer?.invalidate(); pendingTimer = nil
        queue = []
        busy = false
        waiting = false
        alertHost = nil
    }

    // MARK: Warteschlange

    private func enqueue(_ name: String, _ op: @escaping (CPInterfaceController, @escaping (Error?) -> Void) -> Void) {
        queue.append((name, { [weak self] next in
            guard let c = self?.controller else { return next() }
            op(c) { error in
                if let error { Diag.log("CarPlay \(name) fehlgeschlagen: \(error.localizedDescription)") }
                next()
            }
        }))
        runNext()
    }

    private var current = 0
    private var waiting = false

    private func runNext() {
        guard !busy, !queue.isEmpty else { return }
        // Während Mapbox die Navigationsansicht tauscht, eigene Wechsel kurz zurückhalten
        let wait = CarPlayController.shared.alertsPausedUntil.timeIntervalSinceNow
        if wait > 0, !waiting {
            waiting = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(min(wait, 5) + 0.1))
                self?.waiting = false
                self?.runNext()
            }
            return
        }
        guard !waiting else { return }
        busy = true
        current &+= 1
        let id = current
        let item = queue.removeFirst()
        StallLogger.shared.note(item.name)
        let finish: () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.busy, self.current == id else { return }
                self.busy = false
                self.runNext()
            }
        }
        item.run(finish)
        // Bestätigt CarPlay einen Wechsel nicht (Ansicht inzwischen ersetzt), nicht ewig warten – aber protokollieren
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.busy, self.current == id else { return }
            Diag.log("CarPlay \(item.name): keine Bestätigung nach 3 s")
            finish()
        }
    }
}
