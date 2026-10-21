import SwiftUI
import WidgetKit
import ActivityKit

@main
struct MeeterzWidgets: WidgetBundle {
    var body: some Widget {
        NavigationLiveActivity()
    }
}

private let accent = Color(red: 0.78, green: 0.96, blue: 0.20)

/// Navigation auf dem Sperrbildschirm und in der Dynamic Island
struct NavigationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
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
