import Foundation
import UIKit
import MetricKit

/// Abstürze und Hänger im Diagnose-Log festhalten, damit wir Ursachen statt Vermutungen haben.
/// Greift nicht ein, protokolliert nur.
/// - Ausnahmen (z. B. von CarPlay bei einem ungültigen Ansichtswechsel): Name und Grund, direkt beim Absturz
/// - MetricKit: Absturz- und Hängerberichte von iOS (kommen beim nächsten Start bzw. bis zu einen Tag später)
/// - Hauptthread: steht er länger als 2 s, ein Eintrag mit dem, was CarPlay zuletzt tat
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    func start() {
        NSSetUncaughtExceptionHandler { exception in
            Diag.log("ABSTURZ: \(exception.name.rawValue) – \(exception.reason ?? "?") | \(exception.callStackSymbols.prefix(6).joined(separator: " / "))")
            UserDefaults.standard.synchronize()
        }
        // Jeder Start der App ins Log: zeigt, ob iOS die App neu starten musste (z. B. nach Beenden im Hintergrund)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        DispatchQueue.main.async {
            let state = UIApplication.shared.applicationState == .background ? "im Hintergrund" : "im Vordergrund"
            let locked = UIApplication.shared.isProtectedDataAvailable ? "" : ", Daten noch gesperrt (iPhone nicht entsperrt)"
            Diag.log("App gestartet (Build \(build), \(state)\(locked))")
        }
        MXMetricManager.shared.add(self)
        StallLogger.shared.start()
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var parts = ["iOS-Absturzbericht"]
                if let type = crash.exceptionType { parts.append("Typ \(type)") }
                if let signal = crash.signal { parts.append("Signal \(signal)") }
                if let reason = crash.terminationReason { parts.append(reason) }
                if #available(iOS 17.0, *), let e = crash.exceptionReason {
                    parts.append("\(e.exceptionName): \(e.composedMessage)")
                }
                parts.append(Self.frames(crash.callStackTree))
                Diag.log(parts.joined(separator: " · "))
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                Diag.log("iOS-Hängerbericht: \(String(format: "%.1f", seconds)) s · \(Self.frames(hang.callStackTree))")
            }
        }
    }

    /// Die obersten Stellen des betroffenen Threads (Programmteil + Versatz), z. B. „MapboxNavigationCore+0x1a2b“
    private static func frames(_ tree: MXCallStackTree) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = json["callStacks"] as? [[String: Any]] else { return "" }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var result: [String] = []
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = frame, result.count < 8 {
            let name = f["binaryName"] as? String ?? "?"
            let offset = f["offsetIntoBinaryTextSegment"] as? Int ?? 0
            result.append("\(name)+0x\(String(offset, radix: 16))")
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return result.joined(separator: " / ")
    }
}

/// Merkt, wenn der Hauptthread (und damit die ganze Oberfläche inkl. CarPlay) länger als 2 s nicht reagiert
final class StallLogger: @unchecked Sendable {
    static let shared = StallLogger()
    private let lock = NSLock()
    private var lastPong = Date()
    private var reported = false
    /// Zuletzt ausgeführter CarPlay-Ansichtswechsel (wird mit protokolliert)
    var lastAction = "–"

    func start() {
        let thread = Thread { [weak self] in
            while let self {
                DispatchQueue.main.async {
                    self.lock.lock(); self.lastPong = Date(); self.lock.unlock()
                }
                let tick = Date()
                Thread.sleep(forTimeInterval: 0.5)
                self.lock.lock()
                // App war im Hintergrund eingefroren (dieser Faden auch) – das ist kein Hänger
                if Date().timeIntervalSince(tick) > 1.5 { self.lastPong = Date() }
                let stalled = Date().timeIntervalSince(self.lastPong)
                let action = self.lastAction
                let wasReported = self.reported
                if stalled > 2, !wasReported { self.reported = true }
                if stalled < 1, wasReported { self.reported = false }
                self.lock.unlock()
                if stalled > 2, !wasReported {
                    Diag.log("Hauptthread hängt seit \(String(format: "%.1f", stalled)) s (zuletzt CarPlay: \(action))")
                } else if stalled < 1, wasReported {
                    Diag.log("Hauptthread läuft wieder")
                }
            }
        }
        thread.name = "StallLogger"
        thread.qualityOfService = .utility
        thread.start()
    }

    func note(_ action: String) {
        lock.lock(); lastAction = action; lock.unlock()
    }
}
