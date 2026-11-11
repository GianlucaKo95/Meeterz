import SwiftUI
import Combine
import MapboxDirections
import MapboxNavigationCore

/// Wie Apple Karten: Navigiert CarPlay, zeigt das iPhone keine zweite Karte, sondern nur die kommenden Anweisungen
/// untereinander – sauber getrennt, die nächste oben hervorgehoben, darüber Ankunft und Restweg.
@MainActor @Observable
final class DriveSteps {
    static let shared = DriveSteps()

    struct Row: Identifiable, Equatable {
        let id: Int
        let symbol: String
        let text: String
        let detail: String?
        /// Meter bis zu diesem Manöver
        let distance: Double
    }

    private(set) var rows: [Row] = []
    private(set) var arrival: Date?
    private(set) var remainingDistance: Double = 0
    private(set) var remainingTime: TimeInterval = 0
    @ObservationIgnored private var subscription: AnyCancellable?

    func start() {
        subscription = navigationProvider.mapboxNavigation.navigation().routeProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.update(state?.routeProgress) }
            }
    }

    func stop() {
        subscription = nil
        rows = []
    }

    private func update(_ progress: RouteProgress?) {
        guard let progress else { return }
        arrival = Date().addingTimeInterval(progress.durationRemaining)
        remainingDistance = progress.distanceRemaining
        remainingTime = progress.durationRemaining
        var list: [Row] = []
        var along = progress.currentLegProgress.currentStepProgress.distanceRemaining
        let legs = progress.route.legs
        var id = 0
        for legIndex in progress.legIndex..<legs.count {
            let steps = legs[legIndex].steps
            let start = legIndex == progress.legIndex ? progress.currentLegProgress.stepIndex + 1 : 0
            guard start < steps.count else { continue }
            for step in steps[start...] {
                let banner = step.instructionsDisplayedAlongStep?.first?.primaryInstruction.text
                let text = banner?.isEmpty == false ? banner! : step.instructions
                let detail = step.destinations?.first ?? step.exitCodes?.first.map { String(localized: "Ausfahrt \($0)") }
                list.append(Row(id: id, symbol: NavigationLiveActivityController.symbol(type: step.maneuverType, direction: step.maneuverDirection),
                                text: text, detail: detail, distance: along))
                id += 1
                along += step.distance
                if list.count >= 40 { break }
            }
        }
        if list != rows { rows = list }
    }
}

struct DriveStepsView: View {
    let destinationName: String
    let onEnd: () -> Void
    @State private var steps = DriveSteps.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(steps.arrival.map { String(localized: "Ankunft \($0.formatted(date: .omitted, time: .shortened))") } ?? "–")
                            .font(Theme.display(28)).monospacedDigit()
                        Text("\(Format.minutes(seconds: steps.remainingTime)) · \(ActivityFormat.distance(steps.remainingDistance)) · \(destinationName)")
                            .font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
                        Label("Führung läuft in CarPlay", systemImage: "car.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).padding(.top, 2)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Theme.panel)

                Section("Nächste Schritte") {
                    ForEach(steps.rows) { row in
                        HStack(spacing: 12) {
                            Image(systemName: row.symbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(row.id == 0 ? Color.black : Theme.accent)
                                .frame(width: 44, height: 44)
                                .background(RoundedRectangle(cornerRadius: 12).fill(row.id == 0 ? Theme.accent : Theme.panelRaised))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ActivityFormat.distance(row.distance))
                                    .font(Theme.title(row.id == 0 ? 20 : 16)).monospacedDigit()
                                Text(row.text).font(row.id == 0 ? .body.weight(.semibold) : .subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = row.detail {
                                    Text(detail).font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(row.id == 0 ? Theme.panelRaised : Theme.panel)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive, action: onEnd) {
                        Text("Route beenden").font(Theme.title(16)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.danger)
                }
            }
        }
        .onAppear { steps.start() }
        .onDisappear { steps.stop() }
    }
}
