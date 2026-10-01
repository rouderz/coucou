import AVFoundation
import AppKit
import IOKit.ps
import Speech
import os

/// "Hey Mochi" (#61): optional hands-free start, fully on-device.
///
/// While enabled it listens with on-device speech recognition only (never the network; Macs that
/// can't do it on-device don't get the feature). It pauses in Do not disturb, with the screen
/// locked, on battery (optional), while push-to-talk is in use and while Mochi is speaking.
/// "Hey Mochi, <question>" sends the question after ~1.5 s of silence; "Hey Mochi" alone opens
/// the chat listening.
@MainActor
final class WakeWord {
    static let shared = WakeWord()

    enum Mode { case off, waiting, capturing }
    private(set) var mode: Mode = .off

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var sessionStarted = Date.distantPast
    private var lastText = ""
    private var lastChange = Date.distantPast
    private var command = ""
    private var screenLocked = false
    private var watchdog: Timer?
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "voice")

    static let phrases = ["hey mochi", "hey, mochi", "oye mochi", "oye, mochi", "hola mochi", "ey mochi", "hi mochi"]

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WakeWord.shared.screenLocked = true; WakeWord.shared.update() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WakeWord.shared.screenLocked = false; WakeWord.shared.update() }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { WakeWord.shared.tick() }
        }
    }

    /// Why it isn't listening right now (Settings), or nil when it can.
    var blocker: String? {
        let s = AppState.shared
        if !s.wakeWordEnabled { return nil }
        if !VoiceInput.permissionsGranted { return L("Needs Microphone and Speech Recognition (Allow now… above)") }
        if !(SFSpeechRecognizer(locale: VoiceSession.locale(for: s))?.supportsOnDeviceRecognition ?? false) {
            return L("This Mac can't recognize speech on-device in this language, so it stays off")
        }
        if DoNotDisturb.shared.isActive { return L("Paused: Do not disturb") }
        if screenLocked { return L("Paused: screen locked") }
        if s.wakeWordOnlyOnPower && !Self.onACPower { return L("Paused: on battery") }
        return nil
    }

    private var shouldListen: Bool {
        let s = AppState.shared
        return s.wakeWordEnabled && blocker == nil && s.voicePhase == .idle && !s.voiceSpeaking
    }

    /// Starts or stops listening to match the conditions.
    func update() {
        if mode == .capturing { return }
        if shouldListen && mode == .off { listen() }
        if !shouldListen && mode == .waiting { stopAudio(); mode = .off }
    }

    /// Push-to-talk needs the microphone: step aside (update() resumes once it's done).
    func yieldMicrophone() {
        guard mode != .off else { return }
        stopAudio()
        mode = .off
    }

    // MARK: Audio

    private func listen() {
        let locale = VoiceSession.locale(for: AppState.shared)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { return }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // never sends audio anywhere
        request.taskHint = .search
        self.request = request
        Self.installTap(on: engine.inputNode, request: request)
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            log.error("wake word: audio failed \(error.localizedDescription, privacy: .public)")
            return
        }
        task = Self.recognize(recognizer, request: request) { text, final in
            WakeWord.shared.heard(text ?? "", final: final)
        }
        sessionStarted = .now
        lastText = ""
        mode = .waiting
    }

    private func stopAudio() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    /// Fresh recognition every ~50 s so the transcript stays short.
    private func restart() {
        stopAudio()
        mode = .off
        update()
    }

    // MARK: Recognition

    private func heard(_ text: String, final: Bool) {
        if text != lastText { lastText = text; lastChange = .now }
        let lower = text.lowercased()
        switch mode {
        case .waiting:
            guard let range = Self.phrases.compactMap({ lower.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound })
            else {
                if final { restart() }
                return
            }
            mode = .capturing
            command = String(lower[range.upperBound...])
            log.info("wake word heard")
            SoundEngine.shared.play("peek")
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.prompt)
            let state = AppState.shared
            state.voicePhase = .listening
            state.voiceTranscript = Self.clean(command)
        case .capturing:
            if let range = Self.phrases.compactMap({ lower.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound }) {
                command = String(lower[range.upperBound...])
            }
            AppState.shared.voiceTranscript = Self.clean(command)
            if final { finish() }
        case .off:
            break
        }
    }

    private func tick() {
        switch mode {
        case .off, .waiting:
            update()
            if mode == .waiting && Date.now.timeIntervalSince(sessionStarted) > 50 { restart() }
        case .capturing:
            // Silence ends the question; nothing at all for 6 s gives up.
            let quiet = Date.now.timeIntervalSince(lastChange)
            if (!Self.clean(command).isEmpty && quiet > 1.5) || quiet > 6 { finish() }
        }
    }

    private func finish() {
        let question = Self.clean(command)
        stopAudio()
        mode = .off
        command = ""
        let state = AppState.shared
        state.voicePhase = .idle
        state.voiceTranscript = ""
        if !question.isEmpty {
            log.info("wake word: question of \(question.count) characters")
            ChatSession.send(question, state: state, spoken: true)
        }
        // Listening again waits for the answer to be read (update() checks voiceSpeaking).
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    // Audio tap and recognition callbacks run off the main thread.
    nonisolated private static func installTap(on node: AVAudioInputNode, request: SFSpeechAudioBufferRecognitionRequest) {
        nonisolated(unsafe) let req = request
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func recognize(_ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @MainActor @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in update(text, final) }
        }
    }
}
