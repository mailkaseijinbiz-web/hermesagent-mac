import Foundation
import Speech
import AVFoundation

/// Speech-to-text dictation (into the composer) + text-to-speech read-aloud.
/// STT uses `SFSpeechRecognizer` + `AVAudioEngine`; TTS uses `AVSpeechSynthesizer`.
@MainActor
final class VoiceManager: ObservableObject {
    static let shared = VoiceManager()

    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var unavailable = false   // permission denied / recognizer missing

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?
    private var baseText = ""

    private let synth = AVSpeechSynthesizer()

    // ElevenLabs TTS (higher-quality voices). Key comes from ~/.hermes/.env.
    @Published var useElevenLabs: Bool = UserDefaults.standard.bool(forKey: "useElevenLabs") {
        didSet { UserDefaults.standard.set(useElevenLabs, forKey: "useElevenLabs") }
    }
    @Published var elevenLabsVoiceId: String = UserDefaults.standard.string(forKey: "elevenLabsVoiceId") ?? "21m00Tcm4TlvDq8ikWAM" {  // Rachel (multilingual)
        didSet { UserDefaults.standard.set(elevenLabsVoiceId, forKey: "elevenLabsVoiceId") }
    }
    private var audioPlayer: AVAudioPlayer?

    private var elevenLabsKey: String? {
        let k = HermesCLI.shared.mergedEnvironment["ELEVENLABS_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty == false) ? k : nil
    }
    var elevenLabsAvailable: Bool { elevenLabsKey != nil }

    private init() {}

    // MARK: - Dictation (STT)

    /// Toggle listening. `base` is the current composer text (new speech is appended);
    /// `onText` receives the running transcription.
    func toggle(base: String, onText: @escaping (String) -> Void) {
        if isListening { stop() } else { start(base: base, onText: onText) }
    }

    func start(base: String, onText: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { unavailable = true; return }
        self.onText = onText
        self.baseText = base
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard status == .authorized else { self.unavailable = true; return }
                self.beginCapture()
            }
        }
    }

    private func beginCapture() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        // Capture `req` locally (not via self) so the realtime audio thread never
        // touches MainActor state.
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            return
        }
        isListening = true

        task = recognizer?.recognitionTask(with: req) { result, error in
            // Extract Sendable values before hopping to the MainActor.
            let spoken = result?.bestTranscription.formattedString
            let finished = error != nil || (result?.isFinal ?? false)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let spoken {
                    self.onText?(self.baseText.isEmpty ? spoken : self.baseText + " " + spoken)
                }
                if finished { self.stop() }
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }

    // MARK: - Read aloud (TTS)

    /// Speak the text (strips markdown/code noise). Tapping again stops.
    func speak(_ text: String) {
        // Tap-again stops whatever is currently playing (system or ElevenLabs).
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate); isSpeaking = false; return }
        if audioPlayer?.isPlaying == true { audioPlayer?.stop(); audioPlayer = nil; isSpeaking = false; return }

        let clean = Self.plainText(text)
        guard !clean.isEmpty else { return }

        if useElevenLabs, let key = elevenLabsKey {
            isSpeaking = true
            Task { await speakElevenLabs(clean, key: key) }
        } else {
            systemSpeak(clean)
        }
    }

    private func systemSpeak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ja-JP") ?? AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
        isSpeaking = true
    }

    /// Synthesize via the ElevenLabs API and play the returned MP3. Falls back to
    /// the system voice on any error (bad key/permission/network).
    private func speakElevenLabs(_ text: String, key: String) async {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(elevenLabsVoiceId)") else {
            isSpeaking = false; systemSpeak(text); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_multilingual_v2"
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                Log.app.error("ElevenLabs TTS failed (status \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
                isSpeaking = false; systemSpeak(text); return
            }
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            // Reset state when playback finishes (guard against a newer playback).
            let dur = player.duration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000) + 250_000_000)
                guard let self, self.audioPlayer === player else { return }
                self.isSpeaking = false
                self.audioPlayer = nil
            }
        } catch {
            isSpeaking = false; systemSpeak(text)
        }
    }

    /// Strip code fences / markdown markers so TTS reads prose, not symbols.
    private static func plainText(_ s: String) -> String {
        var out: [String] = []
        var inCode = false
        for line in s.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
