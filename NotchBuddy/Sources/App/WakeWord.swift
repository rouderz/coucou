import AVFoundation
import AppKit
import Combine
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
///
/// Cost (#112): the microphone tap only measures the level of each buffer. The speech recognizer
/// is created when speech starts (the last ~300 ms are replayed into it) and ended after ~2 s of
/// silence, so in a quiet room it never runs. There is no polling: conditions are re-checked on
/// events (Do not disturb, lock, power source, voice state, settings).
@MainActor
final class WakeWord {
    static let shared = WakeWord()

    enum Mode { case off, waiting, capturing }
    private(set) var mode: Mode = .off

    private let engine = AVAudioEngine()
    private let gate = WakeGate()
    private var task: SFSpeechRecognitionTask?
    private var recognitionID = 0
    private var recognizers: [String: SFSpeechRecognizer] = [:]
    private var lastText = ""
    private var lastChange = Date.distantPast
    private var command = ""
    private var screenLocked = false
    private var captureTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "voice")

    static let phrases = ["hey mochi", "hey, mochi", "oye mochi", "oye, mochi", "hola mochi", "ey mochi", "hi mochi"]
    /// Only the newest words of a partial result are searched for the wake phrase.
    private static let matchWindow = 80

    func start() {
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WakeWord.shared.screenLocked = true; WakeWord.shared.update() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WakeWord.shared.screenLocked = false; WakeWord.shared.update() }
        }
        // Permissions granted in System Settings: re-check when the app comes back to the front.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WakeWord.shared.update() }
        }
        // Power source changes (AC ↔ battery) arrive as a run-loop event, no polling.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { WakeWord.shared.update() } }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        // Everything else that decides whether it should listen.
        let s = AppState.shared
        let changes: [AnyPublisher<Void, Never>] = [
            s.$wakeWordEnabled.map { _ in () }.eraseToAnyPublisher(),
            s.$wakeWordOnlyOnPower.map { _ in () }.eraseToAnyPublisher(),
            s.$voicePhase.map { _ in () }.eraseToAnyPublisher(),
            s.$voiceSpeaking.map { _ in () }.eraseToAnyPublisher(),
            s.$voiceLanguage.map { _ in () }.eraseToAnyPublisher(),
            s.$dndUntil.map { _ in () }.eraseToAnyPublisher(),
            s.$dndInMeeting.map { _ in () }.eraseToAnyPublisher(),
            s.$dndDuringMeetings.map { _ in () }.eraseToAnyPublisher(),
            s.$focus.map { _ in () }.eraseToAnyPublisher(),
            s.$focusMutesWakeWord.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { WakeWord.shared.update() } }
            .store(in: &cancellables)
        update()
    }

    /// The recognizer for a locale, created once (building one is expensive).
    private func recognizer(for locale: Locale) -> SFSpeechRecognizer? {
        if let cached = recognizers[locale.identifier] { return cached }
        guard let made = SFSpeechRecognizer(locale: locale) else { return nil }
        recognizers[locale.identifier] = made
        return made
    }

    /// Why it isn't listening right now (Settings), or nil when it can.
    var blocker: String? {
        let s = AppState.shared
        if !s.wakeWordEnabled { return nil }
        if !VoiceInput.permissionsGranted { return L("Needs Microphone and Speech Recognition (Allow now… above)") }
        if !(recognizer(for: VoiceSession.locale(for: s))?.supportsOnDeviceRecognition ?? false) {
            return L("This Mac can't recognize speech on-device in this language, so it stays off")
        }
        if s.focusSilencesWakeWord { return L("Paused: focus block") }
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
        let should = shouldListen
        if should && mode == .off { listen() }
        if !should && mode == .waiting { stopAudio(); mode = .off }
    }

    /// Push-to-talk needs the microphone: step aside (update() resumes once it's done).
    func yieldMicrophone() {
        guard mode != .off else { return }
        endCapture()
        stopAudio()
        mode = .off
    }

    // MARK: Audio

    /// Opens the microphone and measures levels; the recognizer starts only when someone speaks.
    private func listen() {
        gate.reset()
        gate.configure(silenceLimit: 2, canStart: true)
        gate.onSpeech = { DispatchQueue.main.async { MainActor.assumeIsolated { WakeWord.shared.beginRecognition() } } }
        Self.installTap(on: engine.inputNode, gate: gate)
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            log.error("wake word: audio failed \(error.localizedDescription, privacy: .public)")
            return
        }
        lastText = ""
        mode = .waiting
    }

    private func stopAudio() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        gate.stop()
        task?.cancel()
        task = nil
        recognitionID += 1
    }

    /// Speech was detected: start the recognizer and replay the pre-roll into it.
    private func beginRecognition() {
        guard mode == .waiting, task == nil || gate.isDetached else { return }
        guard let recognizer = recognizer(for: VoiceSession.locale(for: AppState.shared)),
              recognizer.supportsOnDeviceRecognition else { return }
        task?.cancel()
        recognitionID += 1
        let id = recognitionID
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // never sends audio anywhere
        request.taskHint = .search
        task = Self.recognize(recognizer, request: request) { text, final in
            WakeWord.shared.heard(text ?? "", final: final, id: id)
        }
        lastText = ""
        gate.attach(request)
    }

    /// The recognizer finished (silence, error or length cap): the microphone stays open, waiting for speech.
    private func endRecognition() {
        task = nil
        recognitionID += 1
        gate.reset()
    }

    // MARK: Recognition

    private func newestWords(_ lower: String) -> String { String(lower.suffix(Self.matchWindow)) }

    private func heard(_ text: String, final: Bool, id: Int) {
        guard id == recognitionID else { return }
        if text != lastText { lastText = text; lastChange = .now }
        let lower = text.lowercased()
        switch mode {
        case .waiting:
            let recent = newestWords(lower)
            guard let range = Self.phrases.compactMap({ recent.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound })
            else {
                if final { endRecognition() }
                return
            }
            mode = .capturing
            command = String(recent[range.upperBound...])
            log.info("wake word heard")
            // Keep the same recognition going for the question: longer silence allowed, no new one starts.
            gate.configure(silenceLimit: 6, canStart: false)
            beginCapture()
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

    /// A timer exists only while a question is being captured.
    private func beginCapture() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { WakeWord.shared.captureTick() }
        }
    }

    private func endCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
    }

    private func captureTick() {
        guard mode == .capturing else { endCapture(); return }
        // Silence ends the question; nothing at all for 6 s gives up.
        let quiet = Date.now.timeIntervalSince(lastChange)
        if (!Self.clean(command).isEmpty && quiet > 1.5) || quiet > 6 { finish() }
    }

    private func finish() {
        let question = Self.clean(command)
        endCapture()
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
        // Listening again waits for the answer to be read (voiceSpeaking changes call update()).
        update()
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
    nonisolated private static func installTap(on node: AVAudioInputNode, gate: WakeGate) {
        nonisolated(unsafe) let gate = gate
        // Larger buffers (~85 ms at 48 kHz) mean ~12 callbacks a second instead of ~47.
        node.installTap(onBus: 0, bufferSize: 4096, format: node.outputFormat(forBus: 0)) { buffer, _ in gate.process(buffer) }
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

/// Voice-activity gate between the microphone tap (audio thread) and the speech recognizer.
/// Measures each buffer's level; keeps ~300 ms of pre-roll; hands buffers to a recognition request
/// only while someone is speaking, and ends that request after `silenceLimit` seconds of quiet
/// (or 50 s in total, so the transcript stays short).
final class WakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var preroll: [AVAudioPCMBuffer] = []
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var starting = false
    private var canStart = true
    private var silenceLimit: TimeInterval = 2
    private var lastLoud: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private let threshold: Float = 0.01          // RMS of a buffer; room tone sits well below
    private let maxLength: TimeInterval = 50
    var onSpeech: (@Sendable () -> Void)?

    var isDetached: Bool { lock.lock(); defer { lock.unlock() }; return request == nil }

    func configure(silenceLimit: TimeInterval, canStart: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.silenceLimit = silenceLimit
        self.canStart = canStart
    }

    /// Replays the pre-roll into a new request and routes live buffers to it.
    func attach(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock(); defer { lock.unlock() }
        for buffer in preroll { request.append(buffer) }
        preroll.removeAll()
        self.request = request
        starting = false
        let now = ProcessInfo.processInfo.systemUptime
        lastLoud = now
        startedAt = now
    }

    /// Back to "measuring only" (does not end a request: the recognizer ends it itself).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        request = nil
        starting = false
        preroll.removeAll()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        request?.endAudio()
        request = nil
        starting = false
        preroll.removeAll()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let loud = Self.rms(buffer) > threshold
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if loud { lastLoud = now }
        if let request {
            request.append(buffer)
            if now - lastLoud > silenceLimit || now - startedAt > maxLength {
                request.endAudio()
                self.request = nil
                preroll.removeAll()
            }
            return
        }
        if let copy = Self.copy(buffer) { preroll.append(copy) }
        let keep = starting ? 16 : 4                // ~300 ms idle; a little more while the recognizer spins up
        if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }
        if loud && canStart && !starting {
            starting = true
            onSpeech?()
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        for ch in 0..<Int(buffer.format.channelCount) {
            dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
        }
        return out
    }
}
