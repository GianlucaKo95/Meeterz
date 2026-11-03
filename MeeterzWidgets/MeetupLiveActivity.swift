import SwiftUI
import WidgetKit
import ActivityKit

private let mint = Color(red: 0.435, green: 0.953, blue: 0.855)

/// Treffen: wo die anderen gerade sind – Sperrbildschirm und Dynamic Island
struct MeetupLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetupActivityAttributes.self) { context in
            MeetupLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(mint)
        } dynamicIsland: { context in
            let first = context.state.members.first
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.placeName, systemImage: "person.2.fill")
                        .font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(mint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let at = context.attributes.meetAt {
                        Text(ActivityFormat.time(at)).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(context.state.members, id: \.self) { MemberRow(member: $0) }
                    }
                }
            } compactLeading: {
                Image(systemName: "person.2.fill").foregroundStyle(mint)
            } compactTrailing: {
                if let first { Text(MemberRow.short(first)).font(.caption2.weight(.semibold)).monospacedDigit() }
            } minimal: {
                Image(systemName: "person.2.fill").foregroundStyle(mint)
            }
            .keylineTint(mint)
        }
    }
}

private struct MeetupLockScreen: View {
    let attributes: MeetupActivityAttributes
    let state: MeetupActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.2.fill").foregroundStyle(mint)
                Text(attributes.placeName).font(.headline).lineLimit(1)
                Spacer()
                if let at = attributes.meetAt {
                    Text(ActivityFormat.time(at)).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
            ForEach(state.members, id: \.self) { MemberRow(member: $0) }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

/// „Annika · 4 Min.“ / „Niklas · da“ / „Lisa · 2,3 km“
private struct MemberRow: View {
    let member: MeetupActivityAttributes.Member

    static func short(_ m: MeetupActivityAttributes.Member) -> String {
        if m.here { return String(localized: "da") }
        if let eta = m.eta { return String(localized: "\(max(1, Int((eta.timeIntervalSinceNow / 60).rounded()))) Min.") }
        if let d = m.distance { return ActivityFormat.distance(d) }
        return "–"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(member.initials)
                .font(.caption2.weight(.bold)).foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(member.here ? mint : Color.white.opacity(0.8)))
            Text(member.name).font(.subheadline.weight(.semibold))
            Spacer()
            if let eta = member.eta, !member.here {
                Text("Ankunft \(ActivityFormat.time(eta))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(Self.short(member)).font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(member.here ? mint : .white)
        }
    }
}
