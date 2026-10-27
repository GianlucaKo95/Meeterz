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
final class MeeterzSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
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
    var isSpeaking: Bool { synthesizer.isSpeaking }
    var locale: Locale? = Locale.navigation
    var managesAudioSession = true

    private let synthesizer = AVSpeechSynthesizer()
    private var current: (text: String, instruction: SpokenInstruction)?
    /// Audiositzung gerade aktiv (Navigationskanal im Auto offen)
    private var audioActive = false
    private var pendingSpeech: DispatchWorkItem?
    /// Letzte Ansage (für den Vorlauf nach längerer Stille)
    private var lastSpokenAt: Date?

    override private init() {
        super.init()
        synthesizer.delegate = self
        callObserver.setDelegate(self, queue: .main)
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
                Diag.log("Ansage im Telefonat durch kurzen Ton ersetzt: \(instruction.text.prefix(40))")
            }
            subject.send(VoiceInstructionEvents.DidSpeak(instruction: instruction))
            return
        }
        subject.send(VoiceInstructionEvents.WillSpeak(instruction: instruction))

        // Wie Apple: „An der nächsten Ampel rechts abbiegen“, wenn die Abbiegung an einer Ampel/einem Stoppschild liegt
        let text = LandmarkInstructions.rewrite(instruction, legProgress: legProgress) ?? instruction.text
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceCatalog.selected ?? AVSpeechSynthesisVoice(language: VoiceCatalog.language)

        if let previous = current, synthesizer.isSpeaking {
            subject.send(VoiceInstructionEvents.DidInterrupt(
                interruptedInstruction: previous.instruction, interruptingInstruction: instruction))
            synthesizer.stopSpeaking(at: .immediate)
        }
        current = (text, instruction)
        speakAfterWarmup(utterance, replacesPending: true)
    }

    /// Eigene Ansage (z. B. „Unfall in 3 Kilometern“) in der Navigationsstimme. Unterbricht keine Abbiegeansage,
    /// sondern reiht sich dahinter ein.
    func announce(_ text: String) {
        guard mode != .off, !inCall else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceCatalog.selected ?? AVSpeechSynthesisVoice(language: VoiceCatalog.language)
        speakAfterWarmup(utterance)
    }

    /// Ursache für „erste Ansage fehlt“: Bei der ersten Ansage einer Fahrt schaltet das Auto erst auf den
    /// Navigationskanal um (Musik leiser, Quelle wechseln). Was in dieser Zeit gesprochen wird, kommt im Auto nicht
    /// an – oft der ganze Satz. Darum vor der ersten Ansage nach längerer Stille kurz warten; sonst sofort sprechen.
    private func speakAfterWarmup(_ utterance: AVSpeechUtterance, replacesPending: Bool = false) {
        if replacesPending {   // eine neuere Abbiegeansage ersetzt eine noch wartende
            pendingSpeech?.cancel()
            pendingSpeech = nil
        }
        let wasActive = audioActive
        // Vorlauf nur nach längerer Stille (erste Ansage einer Fahrt): Nach jeder Ansage gibt Meeterz den Ton wieder
        // frei, damit die Musik laut weiterläuft – ein Vorlauf bei jeder Ansage käme an Kreuzungen zu spät.
        let longSilence = lastSpokenAt.map { Date().timeIntervalSince($0) > 5 * 60 } ?? true
        lastSpokenAt = Date()
        activateAudio()
        guard managesAudioSession, !wasActive, longSilence else { synthesizer.speak(utterance); return }
        let warmup: TimeInterval = CarPlayController.shared.isConnected ? 2.0 : 0.4
        Diag.log("Ansage nach \(warmup) s Vorlauf (Audio war aus): \(utterance.speechString.prefix(40))")
        let work = DispatchWorkItem { [weak self] in self?.synthesizer.speak(utterance) }
        pendingSpeech = work
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup, execute: work)
    }

    func stopSpeaking() { synthesizer.stopSpeaking(at: .word) }
    func interruptSpeaking() { synthesizer.stopSpeaking(at: .immediate) }

    // MARK: Audio

    /// Andere Musik leiser stellen, solange die Ansage läuft
    private func activateAudio() {
        guard managesAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        audioActive = true
    }

    private func deactivateAudio() {
        guard managesAudioSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioActive = false
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in
            guard let current = self.current, current.text == text else {
                // Eigene Ansage fertig: Musik wieder lauter, wenn nichts mehr läuft
                if !self.synthesizer.isSpeaking { self.deactivateAudio() }
                return
            }
            self.current = nil
            self.subject.send(VoiceInstructionEvents.DidSpeak(instruction: current.instruction))
            if !self.synthesizer.isSpeaking { self.deactivateAudio() }
        }
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
            pendingSpeech?.cancel()
            pendingSpeech = nil
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
                Diag.log("Ansage wegen Telefonat abgebrochen")
            }
        }
    }
}
