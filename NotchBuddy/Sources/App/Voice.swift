import AVFoundation
import Speech
import os

enum VoicePhase: Equatable { case idle, listening, transcribing }

let voiceLog = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "voice")

// MARK: - Push-to-talk session

/// Hold the shortcut (or click the mic) → listen; let go → send what was said to Mochi's chat.
@MainActor
enum VoiceSession {
    static func begin(_ state: AppState) {
        VoiceOutput.shared.stop()
        guard state.voicePhase == .idle else { return }
        state.voicePhase = .listening
        state.voiceTranscript = ""
        Task {
            do {
                try await VoiceInput.shared.start(locale: locale(for: state)) { text in
                    state.voiceTranscript = text
                }
            } catch {
                state.voicePhase = .idle
                voiceLog.error("voice: \(error.localizedDescription, privacy: .public)")
                state.stateOverride = .question
                state.noteMessage = error.localizedDescription
                state.view = .note
            }
        }
    }

    static func end(_ state: AppState) {
        guard state.voicePhase == .listening else { return }
        state.voicePhase = .transcribing
        Task {
            let text = await VoiceInput.shared.stop()
            state.voicePhase = .idle
            state.voiceTranscript = ""
            guard !text.isEmpty else { return }
            voiceLog.info("voice: heard \(text.count) characters")
            ChatSession.send(text, state: state, spoken: true)
        }
    }

    static func toggle(_ state: AppState) {
        state.voicePhase == .listening ? end(state) : begin(state)
    }

    static func locale(for state: AppState) -> Locale {
        state.voiceLanguage == "auto" ? Locale.current : Locale(identifier: state.voiceLanguage)
    }
}

// MARK: - Speech to text (on-device when the Mac supports it)

@MainActor
final class VoiceInput {
    static let shared = VoiceInput()

    enum Failure: LocalizedError {
        case microphoneDenied, speechDenied, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return L("Coucou needs the microphone for push-to-talk. System Settings → Privacy & Security → Microphone.")
            case .speechDenied:
                return L("Coucou needs Speech Recognition for push-to-talk. System Settings → Privacy & Security → Speech Recognition.")
            case .unavailable(let lang):
                return L("Speech recognition isn't available for \(lang) on this Mac.")
            }
        }
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finished = false
    /// The shortcut was let go while permissions / audio were still starting.
    private var stopRequested = false
    private var starting = false

    func start(locale: Locale, onText: @escaping @MainActor @Sendable (String) -> Void) async throws {
        starting = true
        stopRequested = false
        defer { starting = false }

        guard await Self.microphoneAllowed() else { throw Failure.microphoneDenied }
        guard await Self.speechAllowed() else { throw Failure.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw Failure.unavailable(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        if stopRequested { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        transcript = ""
        finished = false

        Self.installTap(on: engine.inputNode, request: request)
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            self.request = nil
            throw error
        }

        task = Self.recognize(recognizer, request: request) { [weak self] text, isFinal in
            guard let self else { return }
            if let text { self.transcript = text; onText(text) }
            if isFinal { self.finished = true }
        }
        voiceLog.info("voice: listening (\(locale.identifier, privacy: .public), onDevice=\(recognizer.supportsOnDeviceRecognition))")
    }

    /// Stops listening and returns the final transcript (waits briefly for the last words).
    func stop() async -> String {
        stopRequested = true
        // Released before audio started (e.g. the permission prompt was up): wait for start to settle.
        while starting { try? await Task.sleep(for: .milliseconds(50)) }
        guard request != nil else { return "" }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        for _ in 0..<30 where !finished {  // up to 1.5 s for the final result
            try? await Task.sleep(for: .milliseconds(50))
        }
        task?.cancel()
        task = nil
        request = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The audio tap and recognition callbacks run off the main thread: keep them nonisolated.
    nonisolated private static func installTap(on node: AVAudioInputNode,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        nonisolated(unsafe) let req = request
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func recognize(
        _ recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        update: @escaping @MainActor @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in update(text, isFinal) }
        }
    }

    // MARK: Permissions

    nonisolated static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    nonisolated static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    nonisolated static var permissionsGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}

// MARK: - Text to speech (reads Mochi's answer while it's still being written)

@MainActor
final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceOutput()

    private let synth = AVSpeechSynthesizer()
    /// Only answers to a spoken question are read aloud.
    private var armed = false
    private var spoken = 0          // UTF-16 offset already queued
    private var voice: AVSpeechSynthesisVoice?
    private var pending = 0         // utterances queued and not finished

    private override init() {
        super.init()
        synth.delegate = self
    }

    func arm(locale: Locale) {
        stop()
        armed = true
        spoken = 0
        voice = Self.bestVoice(for: locale)
    }

    func disarm() { armed = false }

    /// Streaming answer so far: speak every complete sentence not spoken yet.
    func feed(_ text: String) {
        guard armed else { return }
        let ns = text as NSString
        guard ns.length > spoken else { return }
        let rest = ns.substring(from: spoken) as NSString
        // Last sentence end in the new part: . ! ? … or a line break, followed by whitespace.
        let pattern = try? NSRegularExpression(pattern: #"[.!?…\n](\s|$)"#)
        let matches = pattern?.matches(in: rest as String, range: NSRange(location: 0, length: rest.length)) ?? []
        guard let last = matches.last, last.range.location + 1 < rest.length else { return }
        let end = last.range.location + 1
        speak(rest.substring(to: end))
        spoken += end
    }

    /// The full answer: speak whatever is left, then stop reading this conversation.
    func finish(_ text: String) {
        guard armed else { return }
        let ns = text as NSString
        if ns.length > spoken { speak(ns.substring(from: spoken)) }
        spoken = ns.length
        armed = false
    }

    /// Says a short notice (e.g. a new review request). Never talks over an answer being read.
    func say(_ text: String, locale: Locale) {
        guard !synth.isSpeaking else { return }
        voice = Self.bestVoice(for: locale)
        speak(text)
    }

    func stop() {
        armed = false
        pending = 0
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        AppState.shared.voiceSpeaking = false
    }

    private func speak(_ chunk: String) {
        let clean = chunk
            .replacingOccurrences(of: #"https?://\S+"#, with: "link", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = voice
        pending += 1
        AppState.shared.voiceSpeaking = true
        synth.speak(utterance)
    }

    private static func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let lang = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        let sameRegion = voices.filter { region != nil && $0.language.hasSuffix(region!) }
        let pool = sameRegion.isEmpty ? voices : sameRegion
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: locale.identifier)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
                self.pending = max(0, self.pending - 1)
                if self.pending == 0 { AppState.shared.voiceSpeaking = false }
        }
    }
}

// MARK: - Sending a chat message (typed or spoken)

extension ChatSession {
    static func send(_ query: String, state: AppState, spoken: Bool) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if spoken && state.voiceSpeakReplies {
            VoiceOutput.shared.arm(locale: VoiceSession.locale(for: state))
        } else {
            VoiceOutput.shared.stop()
        }
        if state.view != .prompt { state.view = .prompt }
        state.chatHistory.append(ChatMessage(role: .user, content: query))
        state.stateOverride = .thinking
        Task { await ClaudeService.shared.chat(query: query, context: state.promptContext, state: state) }
    }
}
