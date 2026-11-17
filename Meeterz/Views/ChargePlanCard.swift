import SwiftUI
import MapboxDirections

/// Ladeplan in der Routenvorschau (nur E-Auto mit gewähltem Fahrzeug, Fortbewegung Auto)
struct ChargePlanCard: View {
    @Environment(AppModel.self) private var app
    let route: Route
    /// Bereits übernommene Stopps (Route führt schon über die Säulen)
    let adopted: ChargePlanner.Plan?
    let adopt: (ChargePlanner.Plan) async -> Void
    /// Gerechneter Plan nach oben (Ankunft inkl. Ladezeit in der Vorschau)
    var onPlan: (ChargePlanner.Plan?) -> Void = { _ in }

    @State private var result: Result<ChargePlanner.Plan, ChargePlanner.Failure>?
    @State private var adopting = false
    /// Aufgeklappte Ladealternativen (je Stopp) – wie ABRP
    @State private var openStop: ChargeSite?
    @State private var alternatives: [ChargePlanner.Alternative]?
    /// Ohne Live-Daten erst nach dem Akkustand fragen (vorausgefüllt mit dem letzten Wert) – 17.11.
    @State private var batteryConfirmed = false
    @State private var battery = EVSettings.chargePercent.rounded()
    private var needsBattery: Bool { adopted == nil && app.vehicle.liveSoc == nil && !batteryConfirmed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.car.fill").foregroundStyle(Theme.accent)
                Text("Ladeplan").font(Theme.title(16))
                Spacer()
                Text(startLabel).font(.caption).foregroundStyle(Theme.muted)
            }
            if needsBattery {
                Text("Akkustand jetzt?").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Stepper(value: $battery, in: 5...100, step: 5) {
                    LabeledContent(String(localized: "Akku"), value: "\(Int(battery)) %")
                }
                Text("Ohne Live-Daten vom Auto rechnet der Ladeplan mit diesem Wert.").font(.caption).foregroundStyle(Theme.muted)
                Button("Weiter") {
                    EVSettings.chargePercent = battery
                    batteryConfirmed = true
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("charge-battery-confirm")
            } else if let plan = adopted {
                summary(plan)
                ChargeTimeline(plan: plan)
                stops(plan)
                Label("Ladestopps sind in der Route", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.go)
            } else {
                switch result {
                case nil:
                    HStack(spacing: 8) { ProgressView(); Text("Berechne …").foregroundStyle(Theme.muted) }
                case .failure(.noVehicle):
                    Text("Wähle in den Einstellungen dein Fahrzeug.").foregroundStyle(Theme.muted)
                case .failure(.unreachable(let km)):
                    Text("Mit den Ladesäulen entlang der Route nicht planbar (Reichweite ca. \(Int(EVSettings.rangeForDisplay(planned: km))) km). Meeterz kennt Schnelllader in Deutschland, den Nachbarländern und Italien.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                case .success(let plan):
                    summary(plan)
                    ChargeTimeline(plan: plan)
                    if !plan.direct {
                        stops(plan)
                        Button {
                            adopting = true
                            Task { await adopt(plan); adopting = false }
                        } label: {
                            if adopting { ProgressView() } else { Label("Ladestopps übernehmen", systemImage: "plus.circle.fill") }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(adopting)
                        .accessibilityIdentifier("charge-plan-adopt")
                    }
                }
            }
            Text(ChargeSites.attribution + " · " + String(localized: "Höhen und Wetter: Open-Meteo.com (CC BY 4.0)")).font(.caption2).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelRaised))
        .task(id: "\(route.distance)-\(batteryConfirmed)") {
            guard adopted == nil else { onPlan(adopted); return }
            guard !needsBattery else { onPlan(nil); return }
            result = nil
            onPlan(nil)
            result = await EVSettings.plan(for: route) ?? .failure(.noVehicle)
            if case .success(let plan) = result { onPlan(plan) }
        }
    }

    private var startLabel: String {
        let soc = Int(EVSettings.chargePercent.rounded())
        return app.vehicle.liveSoc != nil ? String(localized: "Start \(soc) % (live)") : String(localized: "Start \(soc) %")
    }

    private func toggleAlternatives(_ stop: ChargePlanner.Stop, _ plan: ChargePlanner.Plan) {
        guard openStop != stop.site else { openStop = nil; return }
        openStop = stop.site
        alternatives = nil
        Task {
            let found = await EVSettings.alternatives(for: stop, in: plan, route: route)
            if openStop == stop.site { alternatives = found }
        }
    }

    /// Andere Säulen für den Stopp: Leistung, Belegung, Zeit mehr/weniger; Antippen übernimmt sie (Plan neu gerechnet)
    @ViewBuilder private func alternativeList(_ plan: ChargePlanner.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let alternatives {
                if alternatives.isEmpty {
                    Text("Keine anderen Schnelllader in der Nähe dieses Stopps.").font(.caption).foregroundStyle(Theme.muted)
                }
                ForEach(alternatives) { alt in
                    Button {
                        choose(alt)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(alt.site.title).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                                Text(verbatim: [alt.site.powerKnown ? "\(Int(alt.site.maxKW)) kW" : nil, alt.site.operatorName.isEmpty ? nil : alt.site.operatorName]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            let minutes = Int((alt.delta / 60).rounded())
                            Text(minutes == 0 ? String(localized: "gleich schnell") : (minutes > 0 ? "+\(minutes) Min." : "\(minutes) Min."))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(minutes > 0 ? Theme.muted : Theme.go)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Suche Alternativen …").font(.caption).foregroundStyle(Theme.muted) }
            }
        }
        .padding(.leading, 62)
    }

    private func choose(_ alt: ChargePlanner.Alternative) {
        openStop = nil
        alternatives = nil
        Diag.log("Ladealternative gewählt: \(alt.site.title)")
        if adopted != nil {
            adopting = true
            Task { await adopt(alt.plan); adopting = false }
        } else {
            result = .success(alt.plan)
            onPlan(alt.plan)
        }
    }

    private func summary(_ plan: ChargePlanner.Plan) -> some View {
        Text(plan.summary).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
    }

    private func stops(_ plan: ChargePlanner.Plan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(plan.stops) { stop in
              VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    Text("\(Int(stop.distanceFromStart / 1000)) km")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.site.title).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                        if let a = stop.availability {
                            Label([a.text, a.priceText].compactMap { $0 }.joined(separator: " · "), systemImage: a.full ? "hourglass" : "circle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(a.free > 0 ? Theme.go : Theme.danger)
                        }
                        Text(verbatim: (stop.site.powerKnown ? "\(Int(stop.site.maxKW)) kW" : String(localized: "kW unbekannt")) + " · \(Int(stop.arrivalPercent)) → \(Int(stop.departurePercent.rounded())) % · " + String(localized: "\(Int((stop.chargeTime / 60).rounded())) Min."))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    Button {
                        toggleAlternatives(stop, plan)
                    } label: {
                        Image(systemName: openStop == stop.site ? "chevron.up" : "arrow.triangle.swap")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Ladealternativen")
                }
                if openStop == stop.site { alternativeList(plan) }
              }
            }
        }
    }
}


/// Zeitleiste wie bei ABRP: Start-Akku → (Ankunft → Abfahrt je Ladestopp) → Ankunft am Ziel
struct ChargeTimeline: View {
    let plan: ChargePlanner.Plan

    private struct Node: Identifiable {
        let id: Int
        let title: String
        let value: String
        let low: Bool
        let charge: Bool
    }

    private var nodes: [Node] {
        var n = [Node(id: 0, title: String(localized: "Start"), value: "\(Int(plan.startPercent.rounded())) %", low: false, charge: false)]
        for (i, stop) in plan.stops.enumerated() {
            n.append(Node(id: i + 1, title: String(localized: "\(Int(stop.distanceFromStart / 1000)) km"),
                          value: "\(Int(stop.arrivalPercent)) → \(Int(stop.departurePercent.rounded())) %",
                          low: stop.arrivalPercent < 12, charge: true))
        }
        n.append(Node(id: 99, title: String(localized: "Ziel"), value: "\(Int(plan.arrivalPercent.rounded())) %",
                      low: plan.arrivalPercent < 15, charge: false))
        return n
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(node.charge ? Theme.accent : Theme.panel)
                                .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                                .frame(width: 22, height: 22)
                            if node.charge {
                                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                            }
                        }
                        Text(node.value).font(.caption.weight(.semibold))
                            .foregroundStyle(node.low ? Theme.danger : Theme.text)
                        Text(node.title).font(.caption2).foregroundStyle(Theme.muted)
                    }
                    .frame(minWidth: 64)
                    if index < nodes.count - 1 {
                        Rectangle().fill(Theme.accent.opacity(0.6)).frame(height: 2).frame(minWidth: 18, maxWidth: .infinity)
                            .padding(.top, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(plan.summary)
    }
}
