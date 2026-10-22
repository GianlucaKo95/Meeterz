import SwiftUI
import WidgetKit

private let accent = Color(red: 0.435, green: 0.953, blue: 0.855)  // Mint aus dem Logo
private let panel = Color(red: 0.039, green: 0.212, blue: 0.251)  // Petrol aus dem Logo

// MARK: Datenquelle (Datenstand der App, alle 30 Min. neu gelesen)

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .preview : (WidgetSnapshotStore.load() ?? .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        WidgetSnapshotStore.appendLog("Zeitplan \(context.family) \(Int(context.displaySize.width))x\(Int(context.displaySize.height)), Gruppe \(WidgetSnapshotStore.groupDescription), Daten: \(WidgetSnapshotStore.loadStatus()), Freunde: \(WidgetSnapshotStore.load()?.friends.count ?? -1)")
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.load() ?? .empty)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        updated: Date(), sharing: true, sharingUntil: nil, incognito: false,
        friends: [
            Friend(name: "Lisa", initials: "LM", distance: 1_200, heading: "nach Café Ella", arrival: Date().addingTimeInterval(900), seen: Date()),
            Friend(name: "Tom", initials: "TK", distance: 8_400, heading: nil, arrival: nil, seen: Date()),
        ],
        meetup: Meetup(place: "Café Ella", with: "Lisa", friendArrival: Date().addingTimeInterval(900), myArrival: nil))
}

private func distance(_ m: Double?) -> String {
    guard let m else { return "" }
    return ActivityFormat.distance(m)
}

private func seen(_ date: Date) -> String {
    let s = Date().timeIntervalSince(date)
    if s < 120 { return "live" }
    if s < 3600 { return "vor \(Int(s / 60)) Min." }
    return "vor \(Int(s / 3600)) Std."
}

private struct Avatar: View {
    let initials: String
    var size: CGFloat = 26
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(accent))
    }
}

// MARK: Freunde in der Nähe

struct FriendsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "meeterz.friends", provider: SnapshotProvider()) { entry in
            FriendsWidgetView(snapshot: entry.snapshot)
                .containerBackground(panel, for: .widget)
                .widgetURL(URL(string: "meeterz://friends"))
        }
        .configurationDisplayName("Freunde")
        .description("Wer in deiner Nähe ist und wer gerade unterwegs ist.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct FriendsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    /// false in CarPlay und StandBy: dort ohne Hintergrund, groß und nur das Wichtigste
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let snapshot: WidgetSnapshot

    var body: some View {
        if family == .systemSmall && !showsBackground {
            glanceable
        } else {
            standard
        }
    }

    /// CarPlay/StandBy: die zwei nächsten Freunde, große Schrift
    private var glanceable: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.friends.isEmpty {
                Text("Niemand teilt").font(.title3.weight(.semibold))
            }
            ForEach(Array(snapshot.friends.prefix(2)), id: \.self) { f in
                HStack(spacing: 10) {
                    Avatar(initials: f.initials, size: 34)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(f.name).font(.title3.weight(.bold)).lineLimit(1)
                        Text(distance(f.distance)).font(.headline).foregroundStyle(accent).monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder private var standard: some View {
        switch family {
        case .accessoryRectangular:
            if let f = snapshot.friends.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.name).font(.headline).widgetAccentable()
                    Text([distance(f.distance), f.heading].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).lineLimit(2)
                }
            } else {
                Text("Gerade teilt niemand").font(.caption)
            }
        default:
            let rows = Array(snapshot.friends.prefix(family == .systemSmall ? 3 : 4))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Freunde").font(.caption.weight(.bold)).foregroundStyle(accent)
                    Spacer()
                    if snapshot.updated > .distantPast {
                        Text(snapshot.updated, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if rows.isEmpty {
                    Spacer()
                    Text("Gerade teilt niemand seinen Standort.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(rows, id: \.self) { f in
                        HStack(spacing: 8) {
                            Avatar(initials: f.initials, size: family == .systemSmall ? 22 : 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(f.name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                Text(f.heading ?? seen(f.seen)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(distance(f.distance)).font(.caption2.weight(.semibold)).foregroundStyle(.white).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: Nächstes Treffen

struct MeetupWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "meeterz.meetup", provider: SnapshotProvider()) { entry in
            MeetupWidgetView(snapshot: entry.snapshot)
                .containerBackground(panel, for: .widget)
                .widgetURL(URL(string: "meeterz://meetups"))
        }
        .configurationDisplayName("Nächstes Treffen")
        .description("Wo ihr euch trefft und wann dein Freund ankommt.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

private struct MeetupWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        if let m = snapshot.meetup {
            switch family {
            case .accessoryInline:
                Text(m.friendArrival.map { "\(m.with) \(ActivityFormat.time($0)) · \(m.place)" } ?? "Treffen: \(m.place)")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.place).font(.headline).widgetAccentable().lineLimit(1)
                    Text("mit \(m.with)").font(.caption)
                    if let eta = m.friendArrival {
                        Text("\(m.with) kommt \(ActivityFormat.time(eta))").font(.caption)
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Treffen").font(.caption.weight(.bold)).foregroundStyle(accent)
                    Text(m.place).font(.headline).foregroundStyle(.white).lineLimit(2)
                    Text("mit \(m.with)").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let eta = m.friendArrival {
                        Label("\(m.with) \(ActivityFormat.time(eta))", systemImage: "car.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                    if let mine = m.myArrival {
                        Label("Du \(ActivityFormat.time(mine))", systemImage: "location.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(accent)
                    }
                }
            }
        } else {
            switch family {
            case .accessoryInline: Text("Kein Treffen geplant")
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Treffen").font(.caption.weight(.bold)).foregroundStyle(accent)
                    Text("Kein Treffen geplant").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Teilen-Status (Sperrbildschirm)

struct SharingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "meeterz.sharing", provider: SnapshotProvider()) { entry in
            SharingWidgetView(snapshot: entry.snapshot)
                .containerBackground(panel, for: .widget)
                .widgetURL(URL(string: "meeterz://sharing"))
        }
        .configurationDisplayName("Teilen")
        .description("Ob du gerade deinen Standort teilst – und wie lange noch.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

private struct SharingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    private var active: Bool {
        snapshot.sharing && !snapshot.incognito && (snapshot.sharingUntil.map { $0 > Date() } ?? true)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if snapshot.incognito {
                Text("Meeterz: Inkognito")
            } else if active, let until = snapshot.sharingUntil {
                Text("Teilst live bis \(ActivityFormat.time(until))")
            } else {
                Text(active ? "Teilst live" : "Teilen pausiert")
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: snapshot.incognito ? "eye.slash.fill" : active ? "location.fill" : "location.slash")
                        .font(.system(size: 16, weight: .bold))
                        .widgetAccentable()
                    if active, let until = snapshot.sharingUntil {
                        Text(ActivityFormat.time(until)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    } else {
                        Text(snapshot.incognito ? "Inkog." : active ? "Live" : "Aus").font(.system(size: 10, weight: .semibold))
                    }
                }
            }
        }
    }
}
