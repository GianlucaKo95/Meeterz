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
                        Text("\(stop.site.powerKnown ? "\(Int(stop.site.maxKW)) kW" : "kW unbekannt") · \(Int(stop.arrivalPercent)) → \(Int(stop.departurePercent.rounded())) % · \(Int((stop.chargeTime / 60).rounded())) Min.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}
