import Foundation
import AVFoundation
import Observation
import Supabase

/// Die vier Momente, in denen ein Freund-Schnipsel abgespielt wird.
enum SoundMoment: String, CaseIterable, Codable, Identifiable {
    case pass, soon, arrived, accepted
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pass: String(localized: "Fährt an dir vorbei")
        case .soon: String(localized: "Noch 5 Minuten bis zum Treffpunkt")
        case .arrived: String(localized: "Am Treffpunkt angekommen")
        case .accepted: String(localized: "Nimmt dein Treffen an")
        }
    }

    var example: String {
        switch self {
        case .pass: String(localized: "„Hup mal, ich bin's!“")
        case .soon: String(localized: "„Bin gleich da, bestell schon mal!“")
        case .arrived: String(localized: "„Wo bleibst du denn?“")
        case .accepted: String(localized: "„Deal, wir sehen uns!“")
        }
    }

    /// Apple-Ansage, falls der Freund nichts aufgenommen hat
    func fallback(name: String) -> String {
        switch self {
        case .pass: String(localized: "\(name) ist gerade an dir vorbeigefahren.")
        case .soon: String(localized: "\(name) ist in etwa fünf Minuten am Treffpunkt.")
        case .arrived: String(localized: "\(name) ist am Treffpunkt angekommen.")
        case .accepted: String(localized: "\(name) hat dein Treffen angenommen.")
        }
    }
}

/// Sound-Pack: eigene Sprachschnipsel aufnehmen/hochladen, Schnipsel angenommener Freunde laden und abspielen.
/// Bucket "sounds", Pfad "<user_id>/<moment>.m4a"; Rechte setzt die Storage-Policy (nur Freunde).
@MainActor @Observable
final class SoundStore: NSObject {
    static let maxDuration: TimeInterval = 5

    /// Version je Nutzer und Moment (0/fehlt = kein Schnipsel); enthält auch meine eigenen
    private(set) var versions: [UUID: [SoundMoment: Int]] = [:]
    private(set) var isRecording = false
    private(set) var recordingMoment: SoundMoment?
    private(set) var playingKey: String?
    private(set) var isBusy = false

    // Einstellungen
    var enabled: Bool = UserDefaults.standard.object(forKey: "sounds.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "sounds.enabled") }
    }
    private(set) var muted: Set<UUID> = Set(
        (UserDefaults.standard.stringArray(forKey: "sounds.muted") ?? []).compactMap(UUID.init(uuidString:))
    )

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var lastPlayed: [String: Date] = [:]
    @ObservationIgnored private var loading = Set<String>()

    private var client: SupabaseClient { Backend.client }
    private let bucket = "sounds"

    private struct Row: Decodable {
        let userId: UUID
        let moment: String
        let version: Int
        enum CodingKeys: String, CodingKey { case userId = "user_id", moment, version }
    }

    func hasClip(_ user: UUID, _ moment: SoundMoment) -> Bool { (versions[user]?[moment] ?? 0) > 0 }

    func isMuted(_ id: UUID) -> Bool { muted.contains(id) }

    func setMuted(_ id: UUID, _ value: Bool) {
        if value { muted.insert(id) } else { muted.remove(id) }
        UserDefaults.standard.set(muted.map { $0.uuidString }, forKey: "sounds.muted")
    }

    // MARK: Synchronisieren

    func sync() async {
        guard let rows: [Row] = try? await client.rpc("friend_sounds").execute().value else { return }
        var next: [UUID: [SoundMoment: Int]] = [:]
        for r in rows {
            if let m = SoundMoment(rawValue: r.moment) { next[r.userId, default: [:]][m] = r.version }
        }
        versions = next
        // kleine Dateien (wenige KB) gleich vorladen, damit das Abspielen sofort klappt
        for (user, moments) in next {
            for (moment, version) in moments { await ensureLocal(user, moment, version) }
        }
    }

    func reset() {
        stopPlayback()
        versions = [:]
    }

    // MARK: Eigene Schnipsel

    func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func startRecording(_ moment: SoundMoment) async {
        guard !isRecording else { return }
        guard await requestMicrophone() else {
            AppModel.shared.show(String(localized: "Mikrofon-Zugriff fehlt (Einstellungen → Meeterz)."))
            return
        }
        stopPlayback()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = Self.tempURL
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 22050,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.record(forDuration: Self.maxDuration)
            recorder = rec
            isRecording = true
            recordingMoment = moment
            stopTask?.cancel()
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.maxDuration + 0.3))
                if !Task.isCancelled { await self?.finishRecording(upload: true) }
            }
        } catch {
            AppModel.shared.show(String(localized: "Aufnahme konnte nicht gestartet werden."))
        }
    }

    /// Beendet die Aufnahme vorzeitig und lädt hoch
    func stopRecording() async { await finishRecording(upload: true) }

    private func finishRecording(upload: Bool) async {
        guard isRecording, let rec = recorder, let moment = recordingMoment else { return }
        stopTask?.cancel()
        rec.stop()
        recorder = nil
        isRecording = false
        recordingMoment = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard upload, let userId = AppModel.shared.profile?.id,
              let data = try? Data(contentsOf: Self.tempURL), data.count > 1500 else { return }
        await setMine(moment, data: data, userId: userId)
    }

    private func setMine(_ moment: SoundMoment, data: Data, userId: UUID) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.storage.from(bucket).upload(
                Self.path(userId, moment), data: data,
                options: FileOptions(cacheControl: "3600", contentType: "audio/mp4", upsert: true)
            )
            let version: Int = try await client.rpc("set_sound", params: ["p_moment": moment.rawValue]).execute().value
            Self.writeCache(data, id: userId, moment: moment, version: version)
            versions[userId, default: [:]][moment] = version
        } catch {
            AppModel.shared.show(String(localized: "Schnipsel konnte nicht gespeichert werden."))
        }
    }

    func removeMine(_ moment: SoundMoment, userId: UUID) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.storage.from(bucket).remove(paths: [Self.path(userId, moment)])
            let _: Int = try await client.rpc("set_sound", params: ["p_moment": moment.rawValue, "remove": "true"] as [String: String]).execute().value
            versions[userId]?[moment] = nil
        } catch {
            AppModel.shared.show(String(localized: "Schnipsel konnte nicht entfernt werden."))
        }
    }

    /// Vor dem Löschen des Kontos
    func deleteFiles(userId: UUID) async {
        let paths = SoundMoment.allCases.map { Self.path(userId, $0) }
        _ = try? await client.storage.from(bucket).remove(paths: paths)
    }

    // MARK: Abspielen

    /// Zur Probe (eigene Schnipsel) – ohne Stummschaltung und Pause
    func preview(user: UUID, _ moment: SoundMoment) async {
        guard let v = versions[user]?[moment], v > 0 else { return }
        await ensureLocal(user, moment, v)
        play(Self.cacheURL(id: user, moment: moment, version: v), key: "\(user)-\(moment.rawValue)")
    }

    /// Spielt den Moment für einen Freund ab; ohne Schnipsel gibt es die Apple-Ansage.
    /// `cooldown` verhindert Wiederholungen (z. B. „fährt vorbei“).
    func trigger(_ moment: SoundMoment, friend: FriendRow, cooldown: TimeInterval = 0, key extra: String = "") async {
        guard enabled, !isMuted(friend.friendId), !isRecording else { return }
        let key = "\(friend.friendId)-\(moment.rawValue)\(extra)"
        if let last = lastPlayed[key], Date().timeIntervalSince(last) < cooldown { return }
        lastPlayed[key] = Date()

        if let v = versions[friend.friendId]?[moment], v > 0 {
            await ensureLocal(friend.friendId, moment, v)
            let url = Self.cacheURL(id: friend.friendId, moment: moment, version: v)
            if FileManager.default.fileExists(atPath: url.path) {
                play(url, key: key)
                return
            }
        }
        speak(moment.fallback(name: friend.displayName.split(separator: " ").first.map(String.init) ?? friend.displayName))
    }

    private func play(_ url: URL, key: String) {
        stopPlayback()
        do {
            let session = AVAudioSession.sharedInstance()
            // Musik wird kurz leiser; Navigationsansagen laufen weiter und werden nicht unterbrochen
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.volume = 1
            p.play()
            player = p
            playingKey = key
        } catch {
            playingKey = nil
        }
    }

    /// Kurze Ansage (z. B. eingehende Nachricht im Auto) – nicht, wenn das Soundpaket aus ist oder gerade aufgenommen wird
    func announce(_ text: String) {
        guard enabled, !isRecording else { return }
        speak(text)
    }

    private func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = VoiceCatalog.selected ?? AVSpeechSynthesisVoice(language: VoiceCatalog.language)
        synth.speak(u)
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingKey = nil
    }

    // MARK: Dateien und Cache

    private func ensureLocal(_ user: UUID, _ moment: SoundMoment, _ version: Int) async {
        let url = Self.cacheURL(id: user, moment: moment, version: version)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let key = url.lastPathComponent
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        if let data = try? await client.storage.from(bucket).download(path: Self.path(user, moment)) {
            Self.writeCache(data, id: user, moment: moment, version: version)
        }
    }

    /// Kleinbuchstaben: Die Storage-Policy vergleicht mit auth.uid()::text
    private static func path(_ id: UUID, _ moment: SoundMoment) -> String {
        "\(id.uuidString.lowercased())/\(moment.rawValue).m4a"
    }

    private static var tempURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("meeterz-aufnahme.m4a") }

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("sounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(id: UUID, moment: SoundMoment, version: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString.lowercased())-\(moment.rawValue)-\(version).m4a")
    }

    private static func writeCache(_ data: Data, id: UUID, moment: SoundMoment, version: Int) {
        let prefix = "\(id.uuidString.lowercased())-\(moment.rawValue)-"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) {
            for f in files where f.hasPrefix(prefix) { try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(f)) }
        }
        try? data.write(to: cacheURL(id: id, moment: moment, version: version))
    }
}

extension SoundStore: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playingKey = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
