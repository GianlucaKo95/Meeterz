import AVFoundation
import CallKit
import AudioToolbox
import Combine
import MapboxDirections
import MapboxNavigationCore

/// Sprachstimmen in der Sprache der App auf dem Gerät. Siri-Stimmen stellt Apple Apps nicht zur Verfügung;
/// wir nutzen die besten installierten Systemstimmen (Premium > Erweitert > Standard).
enum VoiceCatalog {
    static let key = "nav.voice"          // leer = automatisch die beste Stimme

    /// Sprache der Ansagen = Sprache der App (de, en, fr, es, pt, tr, it; sonst en)
    static var language: String { Locale.navigation.language.languageCode?.identifier ?? "en" }

    /// Nur die normalen Systemstimmen – ohne Spaß-Stimmen wie „Eddy“ oder „Grandma“
    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .filter { $0.identifier.contains("com.apple.voice") || $0.identifier.contains("ttsbundle") }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    static var best: AVSpeechSynthesisVoice? {
        // Bevorzugt die Variante der eigenen Region (z. B. de-DE, en-GB, pt-BR), sonst die beste der Sprache
        let region = Locale.current.region?.identifier ?? ""
        return voices.first(where: { $0.language == "\(language)-\(region)" }) ?? voices.first
    }

    /// Gewählte Stimme, sonst die beste verfügbare
    static var selected: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id),
           voice.language.hasPrefix(language) { return voice }   // gewählte Stimme passt nicht mehr zur Sprache → automatisch
        return best
    }

    static var hasBetterThanDefault: Bool { voices.contains { $0.quality.rawValue >= AVSpeechSynthesisVoiceQuality.enhanced.rawValue } }

    static func label(for quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: String(localized: "Premium")
        case .enhanced: String(localized: "Erweitert")
        default: String(localized: "Standard")
        }
    }
}

/// Sprachansagen der Navigation mit der gewählten Stimme (iPhone und CarPlay teilen sich diese Instanz).
@MainActor
final class MeeterzSpeechSynthesizer: NSObject, SpeechSynthesizing {
    static let shared = MeeterzSpeechSynthesizer()

    private let subject = PassthroughSubject<VoiceInstructionEvent, Never>()
    var voiceInstructions: AnyPublisher<VoiceInstructionEvent, Never> { subject.eraseToAnyPublisher() }

    /// Wie Apple Karten: alle Ansagen, nur Warnungen (Unfall, Stau, Sperrung) oder keine – bleibt über Fahrten erhalten
    enum VoiceMode: String, CaseIterable {
        case all, alertsOnly, off
        var next: VoiceMode { self == .all ? .alertsOnly : (self == .alertsOnly ? .off : .all) }
        var symbol: String {
            switch self {
            case .all: "speaker.wave.2.fill"
            case .alertsOnly: "speaker.badge.exclamationmark.fill"
            case .off: "speaker.slash.fill"
            }
        }
        var title: String {
            switch self {
            case .all: String(localized: "Alle Ansagen")
            case .alertsOnly: String(localized: "Nur Warnungen")
            case .off: String(localized: "Ansagen aus")
            }
        }
    }
    static let modeKey = "nav.voiceMode"
    static let mutedKey = "nav.muted"   // alter Schalter (an/aus) – beim ersten Lesen übernommen

    var mode: VoiceMode = {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: MeeterzSpeechSynthesizer.modeKey), let m = VoiceMode(rawValue: raw) { return m }
        return d.bool(forKey: MeeterzSpeechSynthesizer.mutedKey) ? .off : .all
    }() {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode != .all, isSpeaking { interruptSpeaking() }
            Diag.log("Sprachansagen: \(mode.rawValue)")
        }
    }

    /// Für Mapbox (SpeechSynthesizing): stumm = keine Abbiegeansagen
    var muted: Bool {
        get { mode != .all }
        set { mode = newValue ? .off : .all }
    }
    var volume: VolumeMode = .system
    var isSpeaking: Bool { playing != nil }
    var locale: Locale? = Locale.navigation
    var managesAudioSession = true

    // Ansagen werden erst vollständig in Ton umgerechnet und dann selbst abgespielt (statt direkt über
    // AVSpeechSynthesizer zu sprechen). Ursache der Probleme vom 28.10.: Mit dem direkten Sprechen schaltete Meeterz die
    // Audiositzung ein, bevor die Stimme überhaupt Ton lieferte (Stimme laden, Satz berechnen). Das Auto schaltete die
    // Musik stumm, und es kam erst nichts – darum gab es einen festen Vorlauf von 2 s, der jede Ansage verspätete und
    // die erste trotzdem nicht rettete. Jetzt ist der Ton fertig, bevor die Musik leiser wird; die Audiositzung ist
    // genau so lange aktiv, wie die Ansage dauert – das Auto sieht klar, wann sie beginnt und endet.
    private let renderer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?

    private struct Item {
        let id = UUID()
        let text: String
        let instruction: SpokenInstruction?
    }
    private var queue: [Item] = []
    private var playing: Item?
    private var lastEndedAt = Date.distantPast

    override private init() {
        super.init()
        engine.attach(player)
        renderer.delegate = self
        callObserver.setDelegate(self, queue: .main)
        // Audioweg geändert (z. B. CarPlay getrennt): Engine hält an – beim nächsten Mal neu verbinden
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playerFormat = nil }
        }
    }

    // MARK: Telefonat

    /// Während eines Telefonats (auch FaceTime/WhatsApp über CallKit) schweigt die Navigation – wie bei Apple Karten.
    /// Unsere Audiositzung mischt sich mit anderen (damit Musik nur leiser wird); deshalb unterbricht iOS sie bei einem
    /// Anruf nicht von selbst, und die Ansage lief mitten ins Gespräch.
    private let callObserver = CXCallObserver()
    var inCall: Bool { callObserver.calls.contains { !$0.hasEnded } }

    func prepareIncomingSpokenInstructions(_ instructions: [SpokenInstruction], locale: Locale?) {}

    func speak(_ instruction: SpokenInstruction, during legProgress: RouteLegProgress, locale: Locale?) {
        guard !muted, !inCall else {
            if inCall, !muted {
                // Wie Apple Karten: statt der Ansage nur ein kurzer Ton, der das Gespräch kaum stört
                AudioServicesPlaySystemSound(1103)
                Diag.log("Ansage im Telefonat durch kurzen Ton ersetzt: \(instruction.text)")
            }
            subject.send(VoiceInstructionEvents.DidSpeak(instruction: instruction))
            return
        }
        // An Autobahnkreuzen kein „Auf A 57 links halten“, wenn man auf derselben Autobahn bleibt
        if MotorwayContinuation.staysOnMotorway(legProgress) {
            Diag.log("Ansage ausgelassen (bleibt auf der Autobahn): \(instruction.text)")
            subject.send(VoiceInstructionEvents.DidSpeak(instruction: instruction))
            return
        }
        subject.send(VoiceInstructionEvents.WillSpeak(instruction: instruction))

        // Wie Apple: „An der nächsten Ampel rechts abbiegen“, wenn die Abbiegung an einer Ampel/einem Stoppschild liegt
        var text = LandmarkInstructions.rewrite(instruction, legProgress: legProgress) ?? instruction.text
        // Wechsel oder Ausfahrt von der Autobahn: die Richtung schon bei der ersten Ansage, nicht erst bei der letzten
        if let withDirection = MotorwayDirection.add(to: text, legProgress: legProgress,
                                                    distanceAlongStep: instruction.distanceAlongStep) { text = withDirection }
        // Innerorts mit Straßennamen: „auf Hauptstraße“ statt „auf Hauptstraße/L 91“
        text = RoadNames.dropCodes(in: text, legProgress: legProgress)
        // „Jetzt rechts abbiegen, dann links abbiegen“ nur, wenn die zweite Abbiegung sofort folgt
        text = ThenInstructions.apply(to: text, legProgress: legProgress)
        if text != instruction.text { Diag.log("Ansage angepasst: „\(instruction.text)“ → „\(text)“") }

        // Eine neue Abbiegeansage ersetzt eine laufende oder wartende – die alte ist überholt
        if let previous = playing, let old = previous.instruction {
            subject.send(VoiceInstructionEvents.DidInterrupt(interruptedInstruction: old, interruptingInstruction: instruction))
        }
        queue.removeAll { $0.instruction != nil }
        if playing?.instruction != nil { stopCurrent() }
        queue.insert(Item(text: text, instruction: instruction), at: 0)
        pump()
    }

    /// Eigene Ansage (z. B. „Unfall in 3 Kilometern“) in der Navigationsstimme. Unterbricht keine Abbiegeansage,
    /// sondern reiht sich dahinter ein.
    func announce(_ text: String) {
        guard mode != .off, !inCall else { return }
        queue.append(Item(text: text, instruction: nil))
        pump()
    }

    func stopSpeaking() { interruptSpeaking() }

    func interruptSpeaking() {
        queue.removeAll()
        stopCurrent()
        finishSession()
    }

    // MARK: Ablauf

    private func pump() {
        guard playing == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        playing = item
        render(item)
    }

    /// Satz in Ton umrechnen (ohne abzuspielen) – erst danach geht die Audiositzung an
    private var rendering: (item: Item, buffers: [AVAudioPCMBuffer], started: Date)?

    private func render(_ item: Item) {
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.voice = VoiceCatalog.selected ?? AVSpeechSynthesisVoice(language: VoiceCatalog.language)
        rendering = (item, [], Date())
        let id = item.id
        renderer.write(utterance) { [weak self] buffer in
            let pcm = buffer as? AVAudioPCMBuffer
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(pcm, id: id) } }
        }
    }

    private func received(_ buffer: AVAudioPCMBuffer?, id: UUID) {
        guard rendering?.item.id == id else { return }
        if let buffer, buffer.frameLength > 0 {
            rendering?.buffers.append(buffer)
        } else {
            renderDone()   // leerer Puffer = Satz fertig
        }
    }

    /// Fertig berechnet (Endmarke oder – je nach iOS-Version – nur die Meldung „fertig“): abspielen
    private func renderDone() {
        guard let done = rendering else { return }
        rendering = nil
        guard playing?.id == done.item.id else { return }
        let seconds = Date().timeIntervalSince(done.started)
        if seconds > 0.5 { Diag.log("Ansage berechnet in \(String(format: "%.1f", seconds)) s") }
        play(done.buffers, item: done.item)
    }

    private func play(_ buffers: [AVAudioPCMBuffer], item: Item) {
        guard let format = buffers.first?.format else { finish(item); return }
        let wasActive = engine.isRunning
        activateAudio()
        if playerFormat != format {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playerFormat = format
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                Diag.log("Ansage: Audio ließ sich nicht starten (\(error.localizedDescription))")
                finish(item)
                return
            }
        }
        // Kurze Stille vorweg, wenn der Ton gerade erst angeht: Das Auto schaltet auf den Navigationskanal um und
        // verschluckt sonst die ersten Silben. Folgen Ansagen direkt aufeinander, entfällt sie.
        if !wasActive, let silence = Self.silence(format: format, seconds: 0.35) {
            player.scheduleBuffer(silence)
        }
        for (index, buffer) in buffers.enumerated() {
            if index == buffers.count - 1 {
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(item) } }
                }
            } else {
                player.scheduleBuffer(buffer)
            }
        }
        player.play()
        // Jede Ansage vollständig ins Log (vorher nur die ersten 40 Zeichen) – um sie nachträglich prüfen zu können
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
        Diag.log("Ansage über \(route): \(item.text)")
    }

    private static func silence(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * seconds)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let frames = Int(buffer.frameLength)
        let channels = format.isInterleaved ? 1 : Int(format.channelCount)
        let perFrame = format.isInterleaved ? Int(format.channelCount) : 1
        if let data = buffer.floatChannelData {
            for c in 0..<channels { memset(data[c], 0, frames * perFrame * MemoryLayout<Float>.size) }
        } else if let data = buffer.int16ChannelData {
            for c in 0..<channels { memset(data[c], 0, frames * perFrame * MemoryLayout<Int16>.size) }
        } else if let data = buffer.int32ChannelData {
            for c in 0..<channels { memset(data[c], 0, frames * perFrame * MemoryLayout<Int32>.size) }
        }
        return buffer
    }

    private func finish(_ item: Item) {
        guard playing?.id == item.id else { return }
        playing = nil
        if let instruction = item.instruction { subject.send(VoiceInstructionEvents.DidSpeak(instruction: instruction)) }
        if queue.isEmpty { finishSession() } else { pump() }
    }

    /// Laufende Ansage abbrechen (Berechnung und Wiedergabe)
    private func stopCurrent() {
        rendering = nil
        renderer.stopSpeaking(at: .immediate)
        player.stop()
        playing = nil
    }

    /// Ansage zu Ende: Ton aus und dem Auto melden, dass die Musik wieder laut darf
    private func finishSession() {
        guard engine.isRunning || audioActive else { return }
        player.stop()
        engine.stop()
        deactivateAudio()
        lastEndedAt = Date()
    }

    // MARK: Audio

    private var audioActive = false

    /// Andere Musik leiser stellen, solange die Ansage läuft (Navigationsansage: das Auto blendet sie als solche ein)
    private func activateAudio() {
        guard managesAudioSession, !audioActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        audioActive = true
    }

    private func deactivateAudio() {
        guard managesAudioSession, audioActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioActive = false
    }
}

extension MeeterzSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Nach den Puffern einreihen, damit alle schon angekommen sind
        DispatchQueue.main.async { MainActor.assumeIsolated { self.renderDone() } }
    }
}

/// An Autobahnkreuzen und -dreiecken nur ansagen, wenn man die Autobahn wechselt oder verlässt – nicht, wenn man auf
/// derselben bleibt („Auf A 57 links halten“). Das Bild zeigt die Spur weiterhin.
enum MotorwayContinuation {
    static func staysOnMotorway(_ legProgress: RouteLegProgress) -> Bool {
        let current = legProgress.currentStep
        guard let next = legProgress.upcomingStep else { return false }
        guard [.reachFork, .continue, .useLane, .passNameChange].contains(next.maneuverType) else { return false }
        let onMotorway = (current.intersections ?? []).contains { $0.outletRoadClasses?.contains(.motorway) == true }
        let staysMotorway = next.intersections?.first?.outletRoadClasses?.contains(.motorway) == true
        guard onMotorway, staysMotorway else { return false }
        let before = Set((current.codes ?? []).map { $0.replacingOccurrences(of: " ", with: "") })
        let after = Set((next.codes ?? []).map { $0.replacingOccurrences(of: " ", with: "") })
        if !before.isEmpty, !after.isEmpty { return !before.isDisjoint(with: after) }
        // Ohne Nummer: gleicher Straßenname
        let names = Set(current.names ?? []), nextNames = Set(next.names ?? [])
        return !names.isEmpty && !names.isDisjoint(with: nextNames)
    }
}

/// Autobahnwechsel und Ausfahrten: Mapbox nennt die Richtung („Richtung Köln“) oft erst in der letzten Ansage kurz vor
/// dem Kreuz. Gerade an großen Kreuzen bleibt dann kaum Zeit, sich einzuordnen. Fehlt sie, hängen wir sie an jede
/// Ansage dieses Manövers an – wie Apple Karten.
enum MotorwayDirection {
    /// Erst ab dieser Entfernung zum Manöver (die „In 3 Kilometern …“-Ansage). Weiter vorher hieß es sonst
    /// „7 Kilometer weiter der Route folgen, Richtung Krefeld“ – die Richtung gehörte da noch zu nichts (28.10.).
    static let maxDistance: Double = 3_200

    static func add(to text: String, legProgress: RouteLegProgress, distanceAlongStep: Double) -> String? {
        guard distanceAlongStep <= maxDistance, let next = legProgress.upcomingStep,
              [.reachFork, .takeOffRamp, .takeOnRamp, .useLane, .continue, .merge].contains(next.maneuverType) else { return nil }
        let current = legProgress.currentStep
        let onMotorway = (current.intersections ?? []).contains { $0.outletRoadClasses?.contains(.motorway) == true }
        guard onMotorway else { return nil }
        let targets = joinFragments(next.destinations ?? [])
        guard let first = targets.first else { return nil }
        // Steht die Richtung schon drin (meist in der letzten Ansage), nichts doppelt
        if text.range(of: first, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return nil }
        return insert(String(localized: "Richtung \(targets.prefix(2).joined(separator: ", "))"), into: text)
    }

    /// Richtung direkt hinter das erste Manöver setzen – nicht hinter ein angehängtes „Dann …“, sonst klang es, als
    /// gehöre sie zum zweiten Manöver („… Ausfahrt 13. Dann rechts halten auf A 57, Richtung Krefeld“)
    static func insert(_ direction: String, into text: String) -> String {
        var head = text.trimmingCharacters(in: .whitespaces)
        var tail = ""
        if let range = head.range(of: #"[.,]\s+dann\s"#, options: [.regularExpression, .caseInsensitive]) {
            tail = String(head[range.lowerBound...])
            head = String(head[..<range.lowerBound])
        }
        let period = tail.isEmpty && head.hasSuffix(".")
        if period { head.removeLast() }
        return head + ", " + direction + (period ? "." : "") + tail
    }

    /// Mapbox trennt Ziele am Komma; Ortsteile wie „Duisburg-Baerl“ kamen dabei als „Duisburg“, „-Baerl“ an
    static func joinFragments(_ raw: [String]) -> [String] {
        var out: [String] = []
        for part in raw.map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            if part.hasPrefix("-"), let last = out.popLast() { out.append(last + part) } else { out.append(part) }
        }
        return out
    }
}

/// Hat eine Straße einen Namen, nennt die Ansage nur den Namen – nicht zusätzlich die Nummer („Hauptstraße/L 91“,
/// „L 91 (Hauptstraße)“). Autobahnen und Straßen ohne Namen behalten ihre Nummer.
enum RoadNames {
    static func dropCodes(in text: String, legProgress: RouteLegProgress) -> String {
        var result = text
        for step in [legProgress.upcomingStep, legProgress.currentStep].compactMap({ $0 }) {
            let names = (step.names ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !names.isEmpty, let codes = step.codes, !codes.isEmpty else { continue }
            let motorway = (step.intersections ?? []).contains { $0.outletRoadClasses?.contains(.motorway) == true }
            guard !motorway else { continue }
            for code in codes { result = remove(code: code, from: result) }
        }
        return result
    }

    /// Nummer samt Trennzeichen entfernen: „Name/L 91“, „L 91/Name“, „Name (L 91)“, „Name, L 91“
    static func remove(code: String, from text: String) -> String {
        let parts = code.split(whereSeparator: { $0 == " " }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return text }
        let token = "\\b" + parts.joined(separator: "\\s?") + "\\b"
        var out = text
        for pattern in ["\\s*\\(\\s*\(token)\\s*\\)", "\\s*[/,;]\\s*\(token)", "\(token)\\s*[/,;]\\s*"] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out
    }
}

/// Hörprobe in den Einstellungen
@MainActor
final class VoicePreview {
    static let shared = VoicePreview()
    private let synthesizer = AVSpeechSynthesizer()

    func play(_ voice: AVSpeechSynthesisVoice?) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: String(localized: "In 300 Metern links abbiegen, dann haben Sie Ihr Ziel erreicht."))
        utterance.voice = voice ?? VoiceCatalog.best ?? AVSpeechSynthesisVoice(language: VoiceCatalog.language)
        synthesizer.speak(utterance)
    }
}

extension MeeterzSpeechSynthesizer: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard !call.hasEnded else { return }
        MainActor.assumeIsolated {
            // Anruf beginnt (eingehend oder ausgehend): laufende und wartende Ansage sofort beenden
            if isSpeaking { Diag.log("Ansage wegen Telefonat abgebrochen") }
            interruptSpeaking()
        }
    }
}
