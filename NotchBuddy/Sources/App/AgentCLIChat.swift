import Foundation
import OSLog

/// Chat engines that run another agent CLI the user is signed in to (#108): Codex (ChatGPT plan) and
/// Gemini CLI. How each is called and read lives in ChatEngineCLIs.swift; this runs the process.
///
/// Like ClaudeCodeChat it only launches the official binary non-interactively, never reads its
/// credentials, and runs in an empty per-conversation folder: Codex in its read-only sandbox, Gemini
/// with its default approval mode (no edit-capable mode is ever asked for). Its hooks are silenced
/// with COUCOU_INTERNAL=1 so the chat never shows up as a session on the island.
///
/// Neither CLI is resumed by session id here: each turn sends the recent conversation as text, so
/// saved chats can switch engines freely.
@MainActor
final class AgentCLIChat: ChatProvider {
    static let codex = AgentCLIChat(.codex)
    static let gemini = AgentCLIChat(.gemini)

    let engine: ChatEngineCLI
    private var history: [(role: String, text: String)] = []
    private var workDir: URL?
    private var running: Process?
    private static var installs: [ChatEngineCLI: CLITool.Install] = [:]
    private static var looked: Set<ChatEngineCLI> = []

    private init(_ engine: ChatEngineCLI) { self.engine = engine }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var capabilities: ChatCapabilities { [.webSearch] }

    // MARK: Locate

    /// Finds the CLI once per launch (or again when `force`); nil when it isn't installed.
    @discardableResult
    static func locate(_ engine: ChatEngineCLI, force: Bool = false) async -> CLITool.Install? {
        #if APPSTORE
        return nil
        #else
        if looked.contains(engine) && !force { return installs[engine] }
        let found = await Task.detached(priority: .utility) { engine.locate() }.value
        installs[engine] = found
        looked.insert(engine)
        return found
        #endif
    }

    static func cachedInstall(_ engine: ChatEngineCLI) -> CLITool.Install? { installs[engine] }

    // MARK: ChatProvider

    func reset() {
        running?.terminate()
        running = nil
        history = []
        workDir = nil
    }

    func restore(_ messages: [SavedChat.Message]) {
        reset()
        history = messages.suffix(Self.keptTurns).map { (role: $0.user ? "User" : "Assistant", text: $0.text) }
    }

    func describe(_ error: Error) -> String { error.localizedDescription }

    /// Turns kept as context for the next question (each turn re-sends them as text).
    static let keptTurns = 12

    func stream(_ request: ChatRequest, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let install = await Self.locate(engine) else {
            throw Failure(message: ChatEngineFailure.classify(engine, exitCode: nil, text: "")?.message ?? "")
        }
        let prompt = Self.prompt(system: request.systemPrompt, history: history,
                                 context: request.context.map(Self.describe), query: request.query)
        let model = AppState.shared.cliChatModel(engine)
        guard let args = engine.arguments(prompt: prompt, model: model) else {
            throw Failure(message: L("This chat engine isn't available yet."))
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: install.path)
        p.arguments = args
        p.currentDirectoryURL = try conversationDir()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = install.pathEnv
        for (k, v) in ChatEngineCLI.internalEnvironment { env[k] = v }
        p.environment = env
        let stdout = Pipe(), stderr = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = stdout
        p.standardError = stderr

        do { try p.run() } catch {
            throw Failure(message: ChatEngineFailure.classify(engine, exitCode: nil, text: "")?.message
                          ?? error.localizedDescription)
        }
        running = p
        defer { if running === p { running = nil } }

        // stderr is drained in the background so a chatty CLI can't block on a full pipe.
        nonisolated(unsafe) let errHandle = stderr.fileHandleForReading
        let errTask = Task.detached { String(data: errHandle.readDataToEndOfFile(), encoding: .utf8) ?? "" }

        var answer = ChatEngineAnswer(engine)
        var raw = ""
        for try await line in stdout.fileHandleForReading.bytes.lines {
            raw += line + "\n"
            let events = ChatEngineOutput.line(engine, line)
            guard !events.isEmpty else { continue }
            answer.push(events)
            if !answer.text.isEmpty { onText(answer.text) }
        }
        nonisolated(unsafe) let proc = p
        await Task.detached { proc.waitUntilExit() }.value
        let errText = await errTask.value

        // Gemini without stream-json support prints one JSON object at the end.
        if answer.text.isEmpty && engine == .gemini { answer.push(ChatEngineOutput.geminiJSON(raw)) }

        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = ChatEngineFailure.classify(engine, exitCode: p.terminationStatus,
                                                    text: [answer.error, errText].compactMap { $0 }.joined(separator: "\n")) {
            throw Failure(message: failure.message)
        }
        if text.isEmpty, let error = answer.error { throw Failure(message: error) }
        if let usage = answer.usage {
            Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")
                .info("usage kind=chat-\(self.engine.rawValue, privacy: .public) input=\(usage.input) output=\(usage.output)")
        }
        history.append((role: "User", text: request.query))
        history.append((role: "Assistant", text: text))
        history = Array(history.suffix(Self.keptTurns))
        return text
    }

    // MARK: Helpers

    /// One prompt with Mochi's instructions, the recent turns and the new question.
    nonisolated static func prompt(system: String, history: [(role: String, text: String)],
                                   context: String?, query: String) -> String {
        var out = system + "\n\n"
        if !history.isEmpty {
            out += "Conversation so far:\n"
            for turn in history { out += "\(turn.role): \(turn.text)\n\n" }
            out += "---\n"
        }
        if let context, !context.isEmpty { out += context + "\n\n" }
        out += "User: " + query
        return out
    }

    /// The attached context as text (this engine can't open files: it says what's attached).
    private static func describe(_ context: PromptContext) -> String {
        switch context {
        case .window(let app, let title, let url):
            return "Context — App: \(app), Window: \(title)" + (url.map { ", URL: \($0)" } ?? "")
        case .file(let name, _):
            return "The user attached a file named \(name) (this engine can't open it)."
        case .code(let code):
            return code.promptPreamble
        }
    }

    private func conversationDir() throws -> URL {
        if let workDir { return workDir }
        let dir = ChatStore.workDirsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir
        return dir
    }
}
