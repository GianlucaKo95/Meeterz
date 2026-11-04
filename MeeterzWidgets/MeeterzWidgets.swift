import SwiftUI
import WidgetKit
import ActivityKit

@main
struct MeeterzWidgets: WidgetBundle {
    var body: some Widget {
        NavigationLiveActivity()
        MeetupLiveActivity()
        SuggestionWidget()
        FriendsWidget()
        MeetupWidget()
        SharingWidget()
    }
}

private let accent = Color(red: 0.435, green: 0.953, blue: 0.855)  // Mint aus dem Logo

/// Navigation auf dem Sperrbildschirm und in der Dynamic Island
struct NavigationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationActivityAttributes.self) { context in
            FamilyView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(accent)
                        Text(ActivityFormat.distance(s.distanceToTurn))
                            .font(.headline).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ActivityFormat.time(s.arrival))
                            .font(.headline).monospacedDigit()
                        Text("Ankunft").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.instruction)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("\(ActivityFormat.distance(s.remainingDistance)) · \(context.attributes.destinationName)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        FriendChip(state: s)
                    }
                }
            } compactLeading: {
                Image(systemName: s.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(ActivityFormat.distance(s.distanceToTurn))
                    .font(.caption.weight(.semibold)).monospacedDigit()
            } minimal: {
                Image(systemName: s.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
        // Kleine Ansicht: CarPlay-Dashboard (und Apple Watch)
        .supplementalActivityFamilies([.small])
    }
}

/// Sperrbildschirm groß; klein (CarPlay-Dashboard) die Autodaten statt einer zweiten Abbiegeanzeige
private struct FamilyView: View {
    @Environment(\.activityFamily) private var family
    let attributes: NavigationActivityAttributes
    let state: NavigationActivityAttributes.ContentState

    var body: some View {
        if family == .small {
            if state.soc != nil { CarDataView(state: state) } else { SmallTurnView(state: state) }
        } else {
            LockScreenView(attributes: attributes, state: state)
        }
    }
}

/// Akku, Reichweite, Ankunft und Verbrauch dieser Fahrt
private struct CarDataView: View {
    let state: NavigationActivityAttributes.ContentState

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                value("battery.75percent", state.soc.map { "\(Int($0.rounded())) %" }, "Akku")
                value("road.lanes", state.rangeKm.map { "\(Int($0.rounded())) km" }, "Reichweite")
            }
            GridRow {
                value("flag.checkered", state.arrivalSoc.map { "\(Int($0.rounded())) %" }, "Ankunft")
                value("bolt.fill", state.consumption.map { $0.formatted(.number.precision(.fractionLength(1))) }, "kWh/100 km")
            }
        }
        .padding(12)
        .foregroundStyle(.white)
    }

    private func value(_ symbol: String, _ text: String?, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(text ?? "–", systemImage: symbol)
                .font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
                .labelStyle(.titleAndIcon)
                .symbolRenderingMode(.hierarchical)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Ohne Auto: kleine Abbiegeanzeige
private struct SmallTurnView: View {
    let state: NavigationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol).font(.system(size: 26, weight: .bold)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(ActivityFormat.distance(state.distanceToTurn)).font(.headline).monospacedDigit()
                Text("\(ActivityFormat.time(state.arrival)) Ankunft").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(12)
        .foregroundStyle(.white)
    }
}

private struct LockScreenView: View {
    let attributes: NavigationActivityAttributes
    let state: NavigationActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: state.symbol)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ActivityFormat.distance(state.distanceToTurn))
                        .font(.title2.weight(.bold)).monospacedDigit()
                    Text(state.instruction)
                        .font(.subheadline).lineLimit(1)
                }
                Spacer()
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(ActivityFormat.time(state.arrival)) Ankunft")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text("\(ActivityFormat.distance(state.remainingDistance)) · \(attributes.destinationName)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                FriendChip(state: state)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

/// Freund, der zum selben Ziel fährt: Initialen und seine Ankunft
private struct FriendChip: View {
    let state: NavigationActivityAttributes.ContentState

    var body: some View {
        if let name = state.friendName {
            HStack(spacing: 6) {
                Text(state.friendInitials ?? "")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(accent))
                if state.friendHere {
                    Text("\(name) ist da").font(.caption.weight(.semibold))
                } else if let eta = state.friendArrival {
                    Text("\(name) \(ActivityFormat.time(eta))").font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
    }
}
