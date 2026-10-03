import Foundation

// MARK: - Chat engines that run another agent CLI (#108)
//
// Pure logic only (no process is started by the parsers): how each CLI is called, where to look for
// it, how to read its output and how to word its failures. Mirror of windows/src/claude/chatEngines.ts;
// keep both in step.
//
// What is CONFIRMED comes from the CLIs' own open-source repositories and docs (cited below).
// Cursor CLI and Grok CLI are listed but NOT confirmed: their docs could not be read while writing
// this, so they have no flags and no parser yet.
// NOTE: written without a Swift toolchain; it has not been compiled.

enum ChatEngineCLI: String, CaseIterable, Sendable {
    case codex, gemini, cursor, grok

    var name: String {
        switch self {
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        }
    }

    /// Executable name (from the issue; for cursor and grok not yet verified).
    var binary: String { self == .cursor ? "cursor-agent" : rawValue }

    /// Flags and output format checked against the CLI's source or docs.
    var confirmed: Bool { self == .codex || self == .gemini }

    /// Command that signs the user in, when known.
    var loginCommand: String? { self == .codex ? "codex login" : nil }

    static var runnable: [ChatEngineCLI] { allCases.filter(\.confirmed) }

    // Codex: `codex exec [OPTIONS] [PROMPT]`, `--json` = events as JSONL on stdout, `--skip-git-repo-check`,
    // `--model`, `-s/--sandbox read-only|workspace-write|danger-full-access`:
    //   https://github.com/openai/codex/blob/main/codex-rs/exec/src/cli.rs
    //   https://github.com/openai/codex/blob/main/codex-rs/utils/cli/src/shared_options.rs
    //   https://github.com/openai/codex/blob/main/codex-rs/utils/cli/src/sandbox_mode_cli_arg.rs
    // Events: https://github.com/openai/codex/blob/main/codex-rs/exec/src/exec_events.rs
    // Sign-in: `codex login status` exits 0 when signed in, 1 with "Not logged in" (both on stderr):
    //   https://github.com/openai/codex/blob/main/codex-rs/cli/src/login.rs (run_login_status)
    // Docs page: https://developers.openai.com/codex/noninteractive
    //
    // Gemini: `-p/--prompt` = non-interactive, `-o/--output-format text|json|stream-json`, `-m/--model`:
    //   https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/cli-reference.md
    //   https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/headless.md
    //   https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/output/types.ts
    // Exit code 41 = authentication error:
    //   https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/errors.ts
    // Gemini has no documented "am I signed in" command: it is detected from the exit code 41.

    /// Arguments for one non-interactive turn, or nil when the call isn't confirmed.
    /// Chats never edit files: Codex runs in its read-only sandbox. Nothing confirmed makes Gemini
    /// headless runs read-only, so its edit-capable approval modes are never requested; the runner
    /// must still start it in an empty temporary folder.
    func arguments(prompt: String, model: String? = nil) -> [String]? {
        let model = model?.trimmingCharacters(in: .whitespaces)
        let modelArgs = (model?.isEmpty == false) ? ["--model", model!] : []
        switch self {
        case .codex:
            return ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only"] + modelArgs + [prompt]
        case .gemini:
            return ["--output-format", "stream-json"] + modelArgs + ["--prompt", prompt]
        case .cursor, .grok:
            return nil
        }
    }

    /// Arguments that ask the CLI whether it is signed in (exit 0 = signed in), when it has such a command.
    var signInCheck: [String]? { self == .codex ? ["login", "status"] : nil }

    /// Environment marker so the runner's own hooks never reach the island.
    static let internalEnvironment = ["COUCOU_INTERNAL": "1"]

    // MARK: Detection

    /// Where the installers usually put the binary, on top of PATH.
    var fallbackPaths: [String] {
        Self.installDirs(home: FileManager.default.homeDirectoryForCurrentUser.path).map { "\($0)/\(binary)" }
    }

    static func installDirs(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
         "\(home)/.bun/bin", "\(home)/.volta/bin"]
    }

    /// Finds the CLI (login shell first, then the usual folders). Blocking: call it off the main thread.
    nonisolated func locate() -> CLITool.Install? {
        CLITool.locate(binary, fallbacks: fallbackPaths)
    }

    /// True when `codex login status` exits 0. Blocking. Other engines have no such check.
    nonisolated func isSignedIn(_ install: CLITool.Install) -> Bool? {
        guard let args = signInCheck else { return nil }
        let env = ProcessInfo.processInfo.environment.merging(["PATH": install.pathEnv]) { $1 }
        guard let out = CLITool.run(install.path, args, environment: env, timeout: 8) else { return false }
        return out.status == 0
    }
}

// MARK: - Output

enum ChatEngineEvent: Equatable, Sendable {
    case session(String)
    case text(String)
    case usage(input: Int, output: Int)
    case error(String)
    case done
}

enum ChatEngineOutput {
    private static func object(_ line: String) -> [String: Any]? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), let data = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    /// One JSONL line of `codex exec --json`. Each `agent_message` arrives complete (no token deltas).
    static func codexLine(_ line: String) -> [ChatEngineEvent] {
        guard let e = object(line), let type = e["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            return (e["thread_id"] as? String).map { [.session($0)] } ?? []
        case "item.completed":
            guard let item = e["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]
        case "turn.completed":
            var out: [ChatEngineEvent] = []
            if let u = e["usage"] as? [String: Any] {
                out.append(.usage(input: int(u["input_tokens"]), output: int(u["output_tokens"])))
            }
            return out + [.done]
        case "turn.failed":
            let message = (e["error"] as? [String: Any])?["message"] as? String
            return [.error(message ?? "Turn failed")]
        case "error":
            return (e["message"] as? String).map { [.error($0)] } ?? []
        default:
            return []
        }
    }

    /// One JSONL line of `gemini --output-format stream-json`; assistant chunks carry `delta: true`.
    static func geminiLine(_ line: String) -> [ChatEngineEvent] {
        guard let e = object(line), let type = e["type"] as? String else { return [] }
        switch type {
        case "init":
            return (e["session_id"] as? String).map { [.session($0)] } ?? []
        case "message":
            guard e["role"] as? String == "assistant", let text = e["content"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]
        case "error":
            // severity "warning" is non-fatal; the final `result` says whether the run failed.
            guard e["severity"] as? String == "error", let message = e["message"] as? String else { return [] }
            return [.error(message)]
        case "result":
            if e["status"] as? String == "error" {
                return [.error((e["error"] as? [String: Any])?["message"] as? String ?? "Gemini failed")]
            }
            var out: [ChatEngineEvent] = []
            if let s = e["stats"] as? [String: Any] {
                out.append(.usage(input: int(s["input_tokens"]), output: int(s["output_tokens"])))
            }
            return out + [.done]
        default:
            return []
        }
    }

    /// The single object of `gemini --output-format json`: the answer, or its error.
    static func geminiJSON(_ output: String) -> [ChatEngineEvent] {
        guard let e = object(output) else { return [] }
        if let err = e["error"] as? [String: Any] { return [.error(err["message"] as? String ?? "Gemini failed")] }
        var out: [ChatEngineEvent] = []
        if let id = e["session_id"] as? String { out.append(.session(id)) }
        if let text = e["response"] as? String, !text.isEmpty { out.append(.text(text)) }
        return out + [.done]
    }

    static func line(_ engine: ChatEngineCLI, _ line: String) -> [ChatEngineEvent] {
        switch engine {
        case .codex: return codexLine(line)
        case .gemini: return geminiLine(line)
        case .cursor, .grok: return []
        }
    }
}

/// Builds the answer as events come in.
struct ChatEngineAnswer {
    let engine: ChatEngineCLI
    private(set) var parts: [String] = []
    private(set) var sessionID: String?
    private(set) var usage: (input: Int, output: Int)?
    private(set) var error: String?
    private(set) var done = false

    init(_ engine: ChatEngineCLI) { self.engine = engine }

    /// Codex messages are whole paragraphs, Gemini's are chunks to glue together.
    var text: String { parts.joined(separator: engine == .gemini ? "" : "\n\n") }

    mutating func push(_ events: [ChatEngineEvent]) {
        for event in events {
            switch event {
            case .text(let t): parts.append(t)
            case .session(let id): sessionID = id
            case .usage(let i, let o): usage = (i, o)
            case .error(let m): error = m
            case .done: done = true
            }
        }
    }
}

// MARK: - Failures

enum ChatEngineFailure: Equatable {
    case notInstalled(String)
    case notSignedIn(String)
    case rateLimited(String)
    case failed(String)

    var message: String {
        switch self {
        case .notInstalled(let m), .notSignedIn(let m), .rateLimited(let m), .failed(let m): return m
        }
    }

    // Heuristics, NOT taken from the CLIs' docs: the wording of their rate-limit and sign-in errors is
    // not documented, so these look for common phrases and HTTP codes in the text the CLI printed.
    private static let rateLimitPattern = try! NSRegularExpression(
        pattern: #"\b429\b|rate[ _-]?limit|too many requests|usage limit|quota|resource[_ ]exhausted"#, options: .caseInsensitive)
    private static let signedOutPattern = try! NSRegularExpression(
        pattern: #"not logged in|not signed in|please (log|sign) in|unauthorized|\b401\b|invalid (api )?key|authentication (required|failed)"#,
        options: .caseInsensitive)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Names what went wrong. `exitCode` nil means the binary couldn't be started; pass the text the
    /// CLI printed on stderr plus any `error` event message. A run that exited 0 is not a failure.
    static func classify(_ engine: ChatEngineCLI, exitCode: Int32?, text: String) -> ChatEngineFailure? {
        guard engine.confirmed else { return nil }
        guard let exitCode else { return .notInstalled(wording(engine, .notInstalled)) }
        if exitCode == 0 { return nil }  // an answer that mentions "quota" is not an error
        if engine == .gemini && exitCode == 41 { return .notSignedIn(wording(engine, .notSignedIn)) }
        if matches(rateLimitPattern, text) { return .rateLimited(wording(engine, .rateLimited)) }
        if matches(signedOutPattern, text) { return .notSignedIn(wording(engine, .notSignedIn)) }
        let detail = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return .failed(detail.isEmpty ? "\(engine.name) exited with code \(exitCode)." : String(detail.prefix(300)))
    }

    private enum Kind { case notInstalled, notSignedIn, rateLimited }

    // Literal strings so the localization table (scripts/gen-strings.py) picks them up.
    private static func wording(_ engine: ChatEngineCLI, _ kind: Kind) -> String {
        switch (engine, kind) {
        case (.codex, .notInstalled): return L("Codex isn't installed. Install it, or pick another chat engine in Settings.")
        case (.codex, .notSignedIn): return L("Codex isn't signed in. Run `codex login` in a terminal, then ask again.")
        case (.codex, .rateLimited): return L("Codex says you hit its usage limit. Wait a bit, or pick another chat engine.")
        case (_, .notInstalled): return L("Gemini CLI isn't installed. Install it, or pick another chat engine in Settings.")
        case (_, .notSignedIn): return L("Gemini CLI isn't signed in. Run `gemini` in a terminal and sign in, then ask again.")
        case (_, .rateLimited): return L("Gemini says you hit its usage limit. Wait a bit, or pick another chat engine.")
        }
    }
}
