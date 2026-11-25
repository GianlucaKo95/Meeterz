#if KINO
// Kino: IPTV/Videos auf dem CarPlay-Bildschirm – nur während das Auto lädt und steht.
// Nur in internen Builds (Schalter KINO, `testflight.yml -f kino=true`); im App-Store-Build ist nichts davon enthalten.
// Quelle wie bei Couchpotato: M3U-Link (auch Xtream get.php), Live-Sender laufen als HLS (.m3u8).
import AVFoundation
import CarPlay
import SwiftUI
import UIKit

struct KinoChannel: Codable, Hashable {
    let name: String
    let group: String
    let url: String
}

enum M3U {
    static func parse(_ text: String) -> [KinoChannel] {
        var result: [KinoChannel] = []
        var name: String?
        var group = ""
        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                name = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).last.map {
                    String($0).trimmingCharacters(in: .whitespaces) }
                group = attribute("group-title", in: line) ?? ""
            } else if !line.isEmpty, !line.hasPrefix("#"), let n = name {
                result.append(KinoChannel(name: n.isEmpty ? line : n, group: group.isEmpty ? "Sonstige" : group, url: line))
                name = nil
            }
        }
        return result
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: key + "=\"") else { return nil }
        let rest = line[r.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    /// AVPlayer spielt kein rohes MPEG-TS: Xtream-Live-Sender als HLS abrufen (wie Couchpotato liveURL)
    static func playable(_ url: String) -> URL? {
        guard var c = URLComponents(string: url) else { return nil }
        var seg = c.path.split(separator: "/").map(String.init)
        if seg.count == 4, seg[0] == "live", seg[3].hasSuffix(".ts") {
            seg[3] = String(seg[3].dropLast(3)) + ".m3u8"
        } else if seg.count == 3, seg[2].allSatisfy(\.isNumber) {   // Kurzform host/user/pass/123
            seg = ["live"] + seg.dropLast() + [seg[2] + ".m3u8"]
        }
        c.path = "/" + seg.joined(separator: "/")
        return c.url
    }
}

@MainActor
final class KinoStore: ObservableObject {
    static let shared = KinoStore()
    @Published var link = UserDefaults.standard.string(forKey: "kino.link") ?? ""
    @Published private(set) var channels: [KinoChannel] = []
    @Published private(set) var status = ""
    private(set) var recent: [KinoChannel] =
        (UserDefaults.standard.data(forKey: "kino.recent")).flatMap { try? JSONDecoder().decode([KinoChannel].self, from: $0) } ?? []

    private var file: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("kino.m3u") }

    var groups: [String] {
        var seen = Set<String>()
        return channels.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    /// Beim Start aus dem Zwischenspeicher (ohne Netz)
    func loadCached() {
        guard channels.isEmpty, let data = try? Data(contentsOf: file) else { return }
        Task { await parse(data) }
    }

    func reload() async {
        UserDefaults.standard.set(link, forKey: "kino.link")
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { status = "Link prüfen"; return }
        status = "Lädt …"
        do {
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue("VLC/3.0", forHTTPHeaderField: "User-Agent")   // manche Anbieter sperren unbekannte Player
            let (data, _) = try await URLSession.shared.data(for: request)
            try data.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
            await parse(data)
        } catch { status = "Fehler: \(error.localizedDescription)" }
    }

    private func parse(_ data: Data) async {
        let list = await Task.detached { M3U.parse(String(decoding: data, as: UTF8.self)) }.value
        channels = list
        status = "\(list.count) Einträge in \(groups.count) Gruppen"
    }

    func played(_ channel: KinoChannel) {
        recent.removeAll { $0.url == channel.url }
        recent.insert(channel, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(try? JSONEncoder().encode(recent), forKey: "kino.recent")
    }
}

/// Spielt über der Karte im CarPlay-Fenster. Sperre: Auto meldet „lädt“ und das iPhone steht.
@MainActor
final class KinoPlayer {
    static let shared = KinoPlayer()
    private var view: KinoView?
    private var player: AVPlayer?
    private var gate: Timer?
    private(set) var playing: KinoChannel?

    /// Nur beim Laden im Stand
    static var allowed: Bool {
        ChargingSession.shared.active && (AppModel.shared.location.lastLocation?.speed ?? 0) < 1.5
    }

    func play(_ channel: KinoChannel) {
        guard Self.allowed, let url = M3U.playable(channel.url),
              let host = CarPlayController.shared.manager.carPlayMapViewController?.view else { return }
        stop(refresh: false)
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "VLC/3.0"]]))
        let player = AVPlayer(playerItem: item)
        let v = KinoView(player: player, title: channel.name)
        v.frame = host.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(v)   // über allem, auch über der Ladeanzeige
        view = v
        self.player = player
        playing = channel
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        player.play()
        KinoStore.shared.played(channel)
        gate = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !KinoPlayer.allowed { Diag.log("Kino gestoppt: lädt nicht mehr oder Wagen bewegt sich"); KinoPlayer.shared.stop() }
                else if item.status == .failed { KinoPlayer.shared.view?.show("Lässt sich hier nicht abspielen") }
            }
        }
        Diag.log("Kino: \(channel.name)")
        CarPlayController.shared.refreshVoiceButton()
    }

    func stop(refresh: Bool = true) {
        gate?.invalidate()
        gate = nil
        player?.pause()
        player = nil
        view?.removeFromSuperview()
        view = nil
        playing = nil
        if refresh { CarPlayController.shared.refreshVoiceButton() }
    }
}

private final class KinoView: UIView {
    private let label = UILabel()

    init(player: AVPlayer, title: String) {
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        self.layer.addSublayer(layer)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
        show(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        label.text = text
        label.alpha = 1
        UIView.animate(withDuration: 0.6, delay: 4, options: []) { self.label.alpha = 0 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.forEach { $0.frame = bounds.inset(by: safeAreaInsets) }
        label.frame = CGRect(x: 0, y: safeAreaInsets.top + 8, width: bounds.width, height: 28)
    }
}

// MARK: - CarPlay-Listen

@MainActor
enum KinoTemplates {
    /// Knopf oben links: Film beim Laden, X während etwas läuft
    static func button() -> CPBarButton? {
        if KinoPlayer.shared.playing != nil {
            return CPBarButton(image: UIImage(systemName: "xmark.circle.fill") ?? UIImage()) { _ in KinoPlayer.shared.stop() }
        }
        guard KinoPlayer.allowed else { return nil }
        return CPBarButton(image: UIImage(systemName: "film.fill") ?? UIImage()) { _ in open() }
    }

    static func open() {
        let store = KinoStore.shared
        store.loadCached()
        var sections: [CPListSection] = []
        if !store.recent.isEmpty {
            sections.append(CPListSection(items: store.recent.map(item), header: "Zuletzt", sectionIndexTitle: nil))
        }
        let groups = store.groups.map { group -> CPListItem in
            let i = CPListItem(text: group, detailText: nil)
            i.accessoryType = .disclosureIndicator
            i.handler = { _, done in
                push(title: group, items: store.channels.filter { $0.group == group }.map(item))
                done()
            }
            return i
        }
        if groups.isEmpty {
            sections.append(CPListSection(items: [CPListItem(text: "Keine Liste", detailText: "In der App: Profil → Für Entwickler → Kino")]))
            CarPlayUI.shared.push(CPListTemplate(title: "Kino", sections: sections), animated: true)
        } else {
            push(title: "Kino", items: groups, leading: sections)
        }
    }

    private static func item(_ channel: KinoChannel) -> CPListItem {
        let i = CPListItem(text: channel.name, detailText: nil)
        i.handler = { _, done in
            KinoPlayer.shared.play(channel)
            CarPlayUI.shared.popToRoot(animated: true)
            done()
        }
        return i
    }

    /// CarPlay begrenzt Listen – lange Gruppen seitenweise mit „Weitere …“
    private static func push(title: String, items: [CPListItem], leading: [CPListSection] = []) {
        let room = max(1, CPListTemplate.maximumItemCount - leading.reduce(0) { $0 + $1.items.count } - 1)
        var page = Array(items.prefix(room))
        if items.count > room {
            let more = CPListItem(text: "Weitere …", detailText: "\(items.count - room) mehr")
            more.handler = { _, done in push(title: title, items: Array(items.dropFirst(room))); done() }
            page.append(more)
        }
        CarPlayUI.shared.push(CPListTemplate(title: title, sections: leading + [CPListSection(items: page)]), animated: true)
    }
}

// MARK: - iPhone: Einstellungen

struct KinoSettingsSection: View {
    @ObservedObject private var store = KinoStore.shared

    var body: some View {
        Section {
            TextField("M3U-Link", text: $store.link, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote)
            HStack {
                Button("Liste laden") { Task { await store.reload() } }
                Spacer()
                Text(store.status).font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        } header: { Text("Kino (nur intern)") } footer: {
            Text("Läuft in CarPlay nur, solange das Auto lädt und steht. Netflix & Co. bleiben wegen Kopierschutz schwarz.")
        }
        .onAppear { store.loadCached() }
    }
}
#endif
