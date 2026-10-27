import Foundation
import Observation
import UIKit
import SwiftUI
import CarPlay
import CoreLocation

/// Laden verfolgen (wie bei ABRP): Sobald das Auto „lädt“ meldet, Fortschritt bis zum Ziel-Akkustand,
/// Ladeleistung und Restzeit – auf dem iPhone als Karte, in CarPlay als Anzeige über der Karte.
/// Zwischen den Meldungen (ca. alle 30–60 s) wird der Akkustand aus der Ladeleistung hochgerechnet.
@MainActor @Observable
final class ChargingSession {
    static let shared = ChargingSession()

    private(set) var active = false
    private(set) var startPercent: Double = 0
    private(set) var startedAt = Date()
    /// Letzte echte Meldung
    private(set) var reportedPercent: Double = 0
    private(set) var reportedAt = Date()
    /// Ladeleistung in kW (positiv)
    private(set) var powerKW: Double = 0
    /// Bis hierhin laden (Ladeplan-Stopp, sonst 80 %)
    var targetPercent: Double = 80
    private var announcedDone = false
    /// Karte auf dem iPhone weggeklickt – bis zum nächsten Ladevorgang nicht mehr zeigen (CarPlay-Anzeige bleibt)
    var hiddenOnPhone = false

    /// Zuletzt übernommener Ladeplan – liefert das Ladeziel an der jeweiligen Säule
    @ObservationIgnored var plan: ChargePlanner.Plan?

    /// Akkustand jetzt (hochgerechnet seit der letzten Meldung, höchstens 3 Minuten weit)
    var percent: Double {
        guard let vehicle = EVSettings.vehicle, powerKW > 0 else { return reportedPercent }
        let dt = min(Date().timeIntervalSince(reportedAt), 180)
        return min(100, reportedPercent + powerKW * 0.92 * dt / 3600 / vehicle.battery * 100)
    }

    var progress: Double {
        guard targetPercent > startPercent else { return 1 }
        return min(1, max(0, (percent - startPercent) / (targetPercent - startPercent)))
    }

    /// Geschätzte Restzeit bis zum Ziel (Ladekurve, begrenzt durch die aktuelle Leistung der Säule)
    var remaining: TimeInterval? {
        guard let vehicle = EVSettings.vehicle, percent < targetPercent else { return nil }
        return ChargePlanner.chargeTime(vehicle, from: percent, to: targetPercent, siteKW: max(powerKW, 3) * 1.05)
    }

    var done: Bool { percent >= targetPercent - 0.3 }

    /// Aus jeder neuen Live-Meldung
    func update(_ status: VehicleStore.Status?) {
        guard EVSettings.enabled, let status, let soc = status.soc, status.age < 15 * 60 else { end(); return }
        if status.charging == true {
            if !active {
                active = true
                startPercent = soc
                startedAt = Date()
                announcedDone = false
                hiddenOnPhone = false
                targetPercent = target(here: AppModel.shared.location.lastLocation?.coordinate)
                Diag.log("Laden erkannt: \(Int(soc)) % → Ziel \(Int(targetPercent)) %")
            }
            reportedPercent = soc
            reportedAt = status.measuredAt
            powerKW = abs(status.powerKw ?? 0)
            CarPlayChargingOverlay.shared.show()
            if done, !announcedDone {
                announcedDone = true
                let text = String(localized: "Genug geladen: \(Int(percent.rounded())) % – weiter geht's")
                AppModel.shared.show(text, isError: false)
                if CarPlayController.shared.isConnected { AppModel.shared.sounds.announce(text) }
            }
        } else {
            end()
        }
    }

    func end() {
        guard active else { return }
        active = false
        powerKW = 0
        CarPlayChargingOverlay.shared.hide()
        Diag.log("Laden beendet bei \(Int(reportedPercent)) %")
    }

    /// Ziel: Abfahrts-% des nächstgelegenen Stopps im übernommenen Plan (bis 1 km), sonst 80 %
    private func target(here: CLLocationCoordinate2D?) -> Double {
        if let here, let stop = plan?.stops.min(by: { $0.site.coordinate.distance(to: here) < $1.site.coordinate.distance(to: here) }),
           stop.site.coordinate.distance(to: here) < 1_000 {
            return min(100, stop.departurePercent.rounded(.up) + 1)
        }
        return 80
    }

    static func minutes(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded(.up))
        return m < 60 ? String(localized: "\(m) Min.") : String(localized: "\(m / 60) Std. \(m % 60) Min.")
    }
}

// MARK: - CarPlay: Anzeige über der Karte

@MainActor
final class CarPlayChargingOverlay {
    static let shared = CarPlayChargingOverlay()
    private var view: ChargingRingView?
    private var timer: Timer?

    func show() {
        guard CarPlayController.shared.isConnected,
              let host = CarPlayController.shared.manager.carPlayNavigationViewController?.view
                ?? CarPlayController.shared.manager.carPlayMapViewController?.view else { return }
        if view?.superview !== host {
            view?.removeFromSuperview()
            let v = ChargingRingView()
            host.addSubview(v)
            view = v
        }
        layout()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { CarPlayChargingOverlay.shared.layout() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        view?.removeFromSuperview()
        view = nil
    }

    private func layout() {
        guard let view, let host = view.superview else { return }
        let s = ChargingSession.shared
        let size = CGSize(width: 200, height: 200)
        // Mitte der freien Kartenfläche (rechts neben den CarPlay-Leisten)
        let safe = host.bounds.inset(by: host.safeAreaInsets)
        view.frame = CGRect(x: safe.midX - size.width / 2 + 40, y: safe.midY - size.height / 2, width: size.width, height: size.height)
        view.update(progress: s.progress, percent: s.percent, target: s.targetPercent, power: s.powerKW,
                    remaining: s.remaining, done: s.done)
    }
}

/// Ring mit Akkustand, darunter Leistung und Restzeit
final class ChargingRingView: UIView {
    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()
    private let percentLabel = UILabel()
    private let detailLabel = UILabel()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 0.024, green: 0.165, blue: 0.196, alpha: 0.88)
        layer.cornerRadius = 24
        for l in [track, bar] {
            l.fillColor = nil
            l.lineWidth = 12
            l.lineCap = .round
            layer.addSublayer(l)
        }
        track.strokeColor = UIColor.white.withAlphaComponent(0.15).cgColor
        bar.strokeColor = Theme.mintUI.cgColor
        percentLabel.font = .systemFont(ofSize: 34, weight: .heavy)
        percentLabel.textColor = .white
        percentLabel.textAlignment = .center
        detailLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 2
        addSubview(percentLabel)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: 82)
        let path = UIBezierPath(arcCenter: center, radius: 58, startAngle: .pi * 0.75, endAngle: .pi * 2.25, clockwise: true)
        track.path = path.cgPath
        bar.path = path.cgPath
        percentLabel.frame = CGRect(x: 0, y: center.y - 22, width: bounds.width, height: 44)
        detailLabel.frame = CGRect(x: 8, y: bounds.height - 48, width: bounds.width - 16, height: 40)
    }

    func update(progress: Double, percent: Double, target: Double, power: Double, remaining: TimeInterval?, done: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(1)
        bar.strokeEnd = CGFloat(progress)
        bar.strokeColor = (done ? UIColor(red: 1, green: 0.78, blue: 0.34, alpha: 1) : Theme.mintUI).cgColor
        CATransaction.commit()
        percentLabel.text = String(localized: "\(Int(percent.rounded())) %")
        var lines = [(power > 0 ? "\(Int(power.rounded())) kW · " : "") + String(localized: "Ziel \(Int(target)) %")]
        lines.append(done ? String(localized: "Genug geladen") : (remaining.map { String(localized: "noch \(ChargingSession.minutes($0))") } ?? String(localized: "lädt …")))
        detailLabel.text = lines.joined(separator: "\n")
    }
}

// MARK: - iPhone: Karte oben auf der Hauptkarte

struct ChargingCard: View {
    @State private var session = ChargingSession.shared
    @State private var tick = Date()

    var body: some View {
        let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Theme.stroke, lineWidth: 6)
                Circle().trim(from: 0, to: session.progress)
                    .stroke(session.done ? Theme.go : Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(session.percent.rounded())) % · Ziel \(Int(session.targetPercent)) %")
                    .font(Theme.title(16)).foregroundStyle(Theme.text)
                Text(detail).font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer()
            Menu {
                ForEach([60, 70, 80, 90, 100], id: \.self) { p in
                    Button("Bis \(p) %") { session.targetPercent = Double(p) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Ladeziel ändern")
            Button {
                withAnimation { session.hiddenOnPhone = true }
            } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 36)
            }
            .accessibilityLabel("Ladeanzeige schließen")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke))
        .onReceive(timer) { tick = $0 }
        .id(tick)
    }

    private var detail: String {
        var parts: [String] = []
        if session.powerKW > 0 { parts.append(String(localized: "\(Int(session.powerKW.rounded())) kW")) }
        if session.done { parts.append(String(localized: "Genug geladen")) }
        else if let r = session.remaining { parts.append(String(localized: "noch \(ChargingSession.minutes(r)) · fertig \(Format.time.string(from: Date().addingTimeInterval(r)))")) }
        return parts.joined(separator: " · ")
    }
}
