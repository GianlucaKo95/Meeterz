import Foundation

/// Kleines Diagnoseprotokoll (zuletzt 150 Zeilen), in den Einstellungen einsehbar – für Fehler, die nur im Auto auftreten.
enum Diag {
    private static let key = "diag.log"
    private static let lock = NSLock()

    static func log(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        let f = DateFormatter(); f.dateFormat = "dd.MM. HH:mm:ss"
        lines.append("\(f.string(from: Date())) \(text)")
        if lines.count > 150 { lines.removeFirst(lines.count - 150) }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static var text: String { (UserDefaults.standard.stringArray(forKey: key) ?? []).joined(separator: "\n") }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
