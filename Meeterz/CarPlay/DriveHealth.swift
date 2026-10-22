import Foundation
import Combine
import CoreLocation
import MapboxNavigationCore

/// Fahrt-Diagnose fürs Protokoll: Hängt der Hauptthread? Kommen Standort und Routenfortschritt regelmäßig?
/// Läuft, solange CarPlay verbunden ist, und schreibt nur Auffälligkeiten plus eine Zusammenfassung pro 5 Minuten.
@MainActor
final class DriveHealth {
    static let shared = DriveHealth()

    private var running = false
    private var generation = 0
    private var progressSub: AnyCancellable?
    private var lastProgress: Date?
    private var maxProgressGap: TimeInterval = 0
    private var maxMainDelay: TimeInterval = 0
    private var stalls = 0
    private var summaryTimer: Timer?
    private var progressCheck: Timer?
    private var flyoverFrames = 0

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        lastProgress = nil
        progressSub = navigationProvider.mapboxNavigation.navigation().routeProgress
            .compactMap { $0?.routeProgress }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let last = self.lastProgress { self.maxProgressGap = max(self.maxProgressGap, Date().timeIntervalSince(last)) }
                    self.lastProgress = Date()
                }
            }
        // Routenfortschritt bleibt aus (z. B. Abbiegeanzeige zählt nicht weiter)
        progressCheck = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = DriveHealth.shared
                guard AppModel.shared.navigation.isNavigating, let last = s.lastProgress else { return }
                let gap = Date().timeIntervalSince(last)
                guard gap > 6 else { return }
                let loc = AppModel.shared.location.lastLocation
                let age = loc.map { String(format: "%.0f s alt, ±%.0f m", Date().timeIntervalSince($0.timestamp), $0.horizontalAccuracy) } ?? "keiner"
                Diag.log("Fahrt: seit \(Int(gap)) s kein Routenfortschritt (Standort \(age))")
            }
        }
        summaryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { DriveHealth.shared.summary() }
        }
        watchMainThread(generation)
    }

    func stop() {
        guard running else { return }
        summary()
        running = false
        progressSub = nil
        summaryTimer?.invalidate(); summaryTimer = nil
        progressCheck?.invalidate(); progressCheck = nil
    }

    /// Von der Flyover-Karte pro Bild gemeldet
    func frame() { flyoverFrames += 1 }

    private func summary() {
        guard running else { return }
        Diag.log(String(format: "Fahrt (5 Min.): Hauptthread max. %.2f s verzögert, %d Hänger > 0,3 s, Fortschritt max. %.1f s Abstand, Flyover %.0f fps",
                        maxMainDelay, stalls, maxProgressGap, Double(flyoverFrames) / 300))
        maxMainDelay = 0
        stalls = 0
        maxProgressGap = 0
        flyoverFrames = 0
    }

    /// Misst im Hintergrund, wie schnell der Hauptthread reagiert
    private func watchMainThread(_ gen: Int) {
        DispatchQueue(label: "meeterz.drivehealth").async {
            while true {
                let running = DispatchQueue.main.sync { MainActor.assumeIsolated { DriveHealth.shared.running && DriveHealth.shared.generation == gen } }
                guard running else { return }
                let sent = Date()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                _ = done.wait(timeout: .now() + 10)
                let delay = Date().timeIntervalSince(sent)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let s = DriveHealth.shared
                        s.maxMainDelay = max(s.maxMainDelay, delay)
                        if delay > 0.3 {
                            s.stalls += 1
                            if delay > 1 { Diag.log(String(format: "Fahrt: Hauptthread %.1f s blockiert", delay)) }
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
}
