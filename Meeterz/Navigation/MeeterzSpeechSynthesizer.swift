import AVFoundation
import Combine
import MapboxDirections
import MapboxNavigationCore

/// Deutsche Sprachstimmen auf dem Gerät. Siri-Stimmen stellt Apple Apps nicht zur Verfügung;
/// wir nutzen die besten installierten Systemstimmen (Premium > Erweitert > Standard).
enum VoiceCatalog {
    static let key = "nav.voice"          // leer = automatisch die beste Stimme

    /// Nur die normalen Systemstimmen – ohne Spaß-Stimmen wie „Eddy“ oder „Grandma“
    static var germanVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") }
            .filter { $0.identifier.contains("com.apple.voice") || $0.identifier.contains("ttsbundle") }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    static var best: AVSpeechSynthesisVoice? {
        germanVoices.first(where: { $0.language == "de-DE" }) ?? germanVoices.first
    }

    /// Gewählte Stimme, sonst die beste verfügbare
    static var selected: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return best
    }

    static var hasBetterThanDefault: Bool { germanVoices.contains { $0.quality.rawValue >= AVSpeechSynthesisVoiceQuality.enhanced.rawValue } }

    static func label(for quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Erweitert"
        default: "Standard"
        }
    }
}

/// Sprachansagen der Navigation mit der gewählten Stimme (iPhone und CarPlay teilen sich diese Instanz).
@MainActor
final class MeeterzSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    static let shared = MeeterzSpeechSynthesizer()

    private let subject = PassthroughSubject<VoiceInstructionEvent, Never>()
    var voiceInstructions: AnyPublisher<VoiceInstructionEvent, Never> { subject.eraseToAnyPublisher() }

    var muted = false {
        didSet { if muted, isSpeaking { interruptSpeaking() } }
    }
    var volume: VolumeMode = .system
    var isSpeaking: Bool { synthesizer.isSpeaking }
    var locale: Locale? = Locale(identifier: "de_DE")
    var managesAudioSession = true

    private let synthesizer = AVSpeechSynthesizer()
    private var current: (text: String, instruction: SpokenInstruction)?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepareIncomingSpokenInstructions(_ instructions: [SpokenInstruction], locale: Locale?) {}

    func speak(_ instruction: SpokenInstruction, during legProgress: RouteLegProgress, locale: Locale?) {
        guard !muted else {
            subject.send(VoiceInstructionEvents.DidSpeak(instruction: instruction))
            return
        }
        subject.send(VoiceInstructionEvents.WillSpeak(instruction: instruction))

        let utterance = AVSpeechUtterance(string: instruction.text)
        utterance.voice = VoiceCatalog.selected ?? AVSpeechSynthesisVoice(language: "de-DE")

        if let previous = current, synthesizer.isSpeaking {
            subject.send(VoiceInstructionEvents.DidInterrupt(
                interruptedInstruction: previous.instruction, interruptingInstruction: instruction))
            synthesizer.stopSpeaking(at: .immediate)
        }
        current = (instruction.text, instruction)
        activateAudio()
        synthesizer.speak(utterance)
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
    }

    private func deactivateAudio() {
        guard managesAudioSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor in
            guard let current = self.current, current.text == text else { return }
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
        let utterance = AVSpeechUtterance(string: "In 300 Metern links abbiegen, dann haben Sie Ihr Ziel erreicht.")
        utterance.voice = voice ?? VoiceCatalog.best ?? AVSpeechSynthesisVoice(language: "de-DE")
        synthesizer.speak(utterance)
    }
}
