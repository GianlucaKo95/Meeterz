import SwiftUI
import MapboxDirections

/// Ladeplan in der Routenvorschau (nur E-Auto mit gewähltem Fahrzeug, Fortbewegung Auto)
struct ChargePlanCard: View {
    @Environment(AppModel.self) private var app
    let route: Route
    /// Bereits übernommene Stopps (Route führt schon über die Säulen)
    let adopted: ChargePlanner.Plan?
    let adopt: (ChargePlanner.Plan) async -> Void

    @State private var result: Result<ChargePlanner.Plan, ChargePlanner.Failure>?
    @State private var adopting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.car.fill").foregroundStyle(Theme.accent)
                Text("Ladeplan").font(Theme.title(16))
                Spacer()
                Text(startLabel).font(.caption).foregroundStyle(Theme.muted)
            }
            if let plan = adopted {
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
                    Text("Mit den Ladesäulen entlang der Route nicht planbar (Reichweite ca. \(Int(km)) km). Meeterz kennt Schnelllader in Deutschland, den Nachbarländern und Italien.")
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
            Text(ChargeSites.attribution).font(.caption2).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelRaised))
        .task(id: route.distance) {
            guard adopted == nil else { return }
            result = nil
            result = await EVSettings.plan(for: route) ?? .failure(.noVehicle)
        }
    }

    private var startLabel: String {
        let soc = Int(EVSettings.chargePercent.rounded())
        return app.vehicle.liveSoc != nil ? "Start \(soc) % (live)" : "Start \(soc) %"
    }

    private func summary(_ plan: ChargePlanner.Plan) -> some View {
        Text(plan.summary).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
    }

    private func stops(_ plan: ChargePlanner.Plan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(plan.stops) { stop in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(Int(stop.distanceFromStart / 1000)) km")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.site.title).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                        if let a = stop.availability {
                            Label(a.text, systemImage: a.full ? "hourglass" : "circle.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(a.free > 0 ? Theme.go : Theme.danger)
                        }
                        Text("\(stop.site.powerKnown ? "\(Int(stop.site.maxKW)) kW" : "kW unbekannt") · \(Int(stop.arrivalPercent)) → \(Int(stop.departurePercent.rounded())) % · \(Int((stop.chargeTime / 60).rounded())) Min.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
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
        var n = [Node(id: 0, title: "Start", value: "\(Int(plan.startPercent.rounded())) %", low: false, charge: false)]
        for (i, stop) in plan.stops.enumerated() {
            n.append(Node(id: i + 1, title: "\(Int(stop.distanceFromStart / 1000)) km",
                          value: "\(Int(stop.arrivalPercent)) → \(Int(stop.departurePercent.rounded())) %",
                          low: stop.arrivalPercent < 12, charge: true))
        }
        n.append(Node(id: 99, title: "Ziel", value: "\(Int(plan.arrivalPercent.rounded())) %",
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
                                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                            }
                        }
                        Text(node.value).font(.caption.weight(.bold))
                            .foregroundStyle(node.low ? Theme.danger : Theme.text)
                        Text(node.title).font(.caption2).foregroundStyle(Theme.muted)
                    }
                    .frame(minWidth: 64)
                    if index < nodes.count - 1 {
                        Rectangle().fill(Theme.accent.opacity(0.6)).frame(height: 2).frame(minWidth: 18, maxWidth: .infinity)
                            .padding(.top, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(plan.summary)
    }
}
