import Foundation
import OSLog

/// Chat engine that runs the user's own Claude Code CLI, signed in with their
/// Claude subscription, instead of calling the Anthropic API with a key.
///
/// It only launches the official, unmodified `claude` binary in print mode and
/// never reads, stores or forwards Claude credentials (see Anthropic's
/// "Authentication and credential use" terms for Claude Code).
///
/// Each conversation runs in its own temporary folder with a tight tool set —
/// web search, web fetch and reading files inside that folder — so the chat can
/// never touch the user's files beyond what they drop on the island.
@MainActor
final class ClaudeCodeChat {
    static let shared = ClaudeCodeChat()

    enum Failure: LocalizedError {
        case notInstalled
        case notSignedIn
        case outdated
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Claude Code isn't installed. Install it, or switch the chat engine to an API key in Settings."
            case .notSignedIn:
                return "Claude Code isn't signed in. Run `claude` in Terminal and sign in with /login."
            case .outdated:
                return "Your Claude Code is too old for this model. Run `claude update` in Terminal (or pick another model in Settings), then ask again."
            case .failed(let message):
                return message
            }
        }
    }

    typealias Install = CLITool.Install

    private(set) static var install: Install?
    private static var lookupDone = false

    private var sessionID: String?
    private var workDir: URL?
    private var running: Process?

    var hasSession: Bool { sessionID != nil }

    // MARK: - Locate the CLI

    /// Finds `claude` once per launch (login shell first, then usual install paths).
    @discardableResult
    static func locate(force: Bool = false) async -> Install? {
        #if APPSTORE
        return nil  // The sandbox can't launch other executables.
        #else
        if lookupDone && !force { return install }
        let found = await Task.detached(priority: .utility) { Self.lookup() }.value
        install = found
        lookupDone = true
        return found
        #endif
    }

    nonisolated private static func lookup() -> Install? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CLITool.locate("claude", fallbacks: [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ])
    }

    // MARK: - Conversation

    /// Forgets the current conversation and its temporary folder.
    func reset() {
        running?.terminate()
        running = nil
        sessionID = nil
        if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
    }

    /// Sends one user turn. `onText` receives the answer so far while it streams.
    /// Returns the final answer text.
    func send(query: String,
              context: PromptContext?,
              model: String,
              systemPrompt: String,
              onText: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let install = await Self.locate() else { throw Failure.notInstalled }

        let dir = try conversationDir()
        var prompt = ""
        if sessionID == nil, let context {
            prompt = contextPreamble(context, in: dir)
        }
        prompt += query

        var args = [
            "-p",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", model,
            "--tools", "WebSearch,WebFetch,Read",
            "--allowedTools", "WebSearch,WebFetch",
            "--permission-mode", "dontAsk",
            "--strict-mcp-config",
            "--append-system-prompt", systemPrompt,
        ]
        if let sessionID { args += ["--resume", sessionID] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: install.path)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = install.pathEnv
        env["COUCOU_INTERNAL"] = "1"  // Coucou's own hook ignores this session.
        p.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        do { try p.run() } catch { throw Failure.failed("Couldn't start Claude Code: \(error.localizedDescription)") }
        running = p
        defer { if running === p { running = nil } }

        // The prompt goes through stdin so a question starting with "-" is never read as a flag.
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        var streamed = ""
        var resultText: String?
        var resultIsError = false
        var authProblem = false

        for try await line in stdout.fileHandleForReading.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "system":
                if let sid = obj["session_id"] as? String { sessionID = sid }
                if obj["subtype"] as? String == "api_retry",
                   let err = obj["error"] as? String,
                   ["authentication_failed", "oauth_org_not_allowed"].contains(err) {
                    authProblem = true
                    p.terminate()
                }
            case "stream_event":
                if let event = obj["event"] as? [String: Any],
                   let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    streamed += text
                    onText(streamed)
                }
            case "result":
                if let sid = obj["session_id"] as? String { sessionID = sid }
                resultText = obj["result"] as? String
                resultIsError = obj["is_error"] as? Bool ?? false
                logUsage(obj, model: model)
            default:
                break
            }
        }

        nonisolated(unsafe) let proc = p
        await Task.detached { proc.waitUntilExit() }.value

        if authProblem { throw Failure.notSignedIn }
        if let resultText, !resultIsError { return resultText }

        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = [resultText, errText].compactMap { $0 }.first { !$0.isEmpty }
            ?? "Claude Code exited with code \(p.terminationStatus)."
        if message.localizedCaseInsensitiveContains("claude update")
            || message.localizedCaseInsensitiveContains("or newer is required") {
            throw Failure.outdated
        }
        if message.localizedCaseInsensitiveContains("login") || message.localizedCaseInsensitiveContains("not logged in") {
            throw Failure.notSignedIn
        }
        throw Failure.failed(String(message.suffix(400)))
    }

    // MARK: - Helpers

    private func conversationDir() throws -> URL {
        if let workDir { return workDir }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Coucou-chat", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir
        return dir
    }

    /// Describes the attached window, or copies the dropped file into the
    /// conversation folder so the Read tool can open it.
    private func contextPreamble(_ context: PromptContext, in dir: URL) -> String {
        switch context {
        case .window(let app, let title, let url):
            var text = "Context — App: \(app), Window: \(title)"
            if let url { text += ", URL: \(url)" }
            return text + "\n\n"
        case .file(let name, let fileURL):
            guard let fileURL else { return "File: \(name)\n\n" }
            let dest = dir.appendingPathComponent(fileURL.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: fileURL, to: dest)
                return "The user attached the file ./\(dest.lastPathComponent). Read it with the Read tool before answering.\n\n"
            } catch {
                return "File: \(name) (it could not be copied, so it can't be read)\n\n"
            }
        }
    }

    private func logUsage(_ result: [String: Any], model: String) {
        guard let u = result["usage"] as? [String: Any] else { return }
        let input  = u["input_tokens"] as? Int ?? 0
        let output = u["output_tokens"] as? Int ?? 0
        let cacheW = u["cache_creation_input_tokens"] as? Int ?? 0
        let cacheR = u["cache_read_input_tokens"] as? Int ?? 0
        Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")
            .info("usage kind=chat-claude-code model=\(model, privacy: .public) input=\(input) cache_write=\(cacheW) cache_read=\(cacheR) output=\(output)")
    }
}
