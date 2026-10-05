import XCTest
@testable import Coucou

/// Chat engines that run other agent CLIs (#108): invocation, output parsing, failures.
/// The samples match the event types defined in the CLIs' own sources (codex-rs/exec/src/exec_events.rs,
/// gemini-cli packages/core/src/output/types.ts). They are NOT recordings of a real run.
final class ChatEngineCLITests: XCTestCase {
    private let codex = [
        #"{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"Thinking"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Hello there."}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Anything else?"}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}"#,
    ]
    private let gemini = [
        #"{"type":"init","timestamp":"2025-10-10T12:00:00.000Z","session_id":"abc-123","model":"gemini-2.5-pro"}"#,
        #"{"type":"message","timestamp":"t","role":"user","content":"Hi"}"#,
        #"{"type":"message","timestamp":"t","role":"assistant","content":"Hel","delta":true}"#,
        #"{"type":"tool_use","timestamp":"t","tool_name":"read_file","tool_id":"t1","parameters":{}}"#,
        #"{"type":"error","timestamp":"t","severity":"warning","message":"Loop detected"}"#,
        #"{"type":"message","timestamp":"t","role":"assistant","content":"lo!","delta":true}"#,
        #"{"type":"result","timestamp":"t","status":"success","stats":{"total_tokens":30,"input_tokens":20,"output_tokens":10,"cached":0,"input":20,"duration_ms":900,"tool_calls":1,"models":{}}}"#,
    ]

    func testCodexStream() {
        var answer = ChatEngineAnswer(.codex)
        for l in codex { answer.push(ChatEngineOutput.codexLine(l)) }
        XCTAssertEqual(answer.sessionID, "0199a213-81c0-7800-8aa1-bbab2a035a53")
        XCTAssertEqual(answer.text, "Hello there.\n\nAnything else?")
        XCTAssertEqual(answer.usage?.input, 24763)
        XCTAssertEqual(answer.usage?.output, 122)
        XCTAssertTrue(answer.done)
        XCTAssertNil(answer.error)
    }

    func testCodexErrorsAndJunk() {
        XCTAssertEqual(ChatEngineOutput.codexLine(#"{"type":"turn.failed","error":{"message":"boom"}}"#), [.error("boom")])
        XCTAssertEqual(ChatEngineOutput.codexLine(#"{"type":"error","message":"fatal"}"#), [.error("fatal")])
        XCTAssertEqual(ChatEngineOutput.codexLine("Reading prompt from stdin..."), [])
        XCTAssertEqual(ChatEngineOutput.codexLine("{not json"), [])
    }

    func testGeminiStream() {
        var answer = ChatEngineAnswer(.gemini)
        for l in gemini { answer.push(ChatEngineOutput.geminiLine(l)) }
        XCTAssertEqual(answer.sessionID, "abc-123")
        XCTAssertEqual(answer.text, "Hello!")
        XCTAssertEqual(answer.usage?.input, 20)
        XCTAssertTrue(answer.done)
        XCTAssertNil(answer.error)
    }

    func testGeminiErrorsAndSingleJSON() {
        XCTAssertEqual(ChatEngineOutput.geminiLine(#"{"type":"result","timestamp":"t","status":"error","error":{"type":"Error","message":"quota"}}"#),
                       [.error("quota")])
        XCTAssertEqual(ChatEngineOutput.geminiJSON(#"{"session_id":"s1","response":"Hi","stats":{"models":{}}}"#),
                       [.session("s1"), .text("Hi"), .done])
        XCTAssertEqual(ChatEngineOutput.geminiJSON(#"{"error":{"type":"ApiError","message":"nope","code":429}}"#), [.error("nope")])
        XCTAssertEqual(ChatEngineOutput.geminiJSON("not json"), [])
    }

    func testInvocationIsReadOnlyAndOnlyForConfirmedCLIs() {
        XCTAssertEqual(ChatEngineCLI.codex.arguments(prompt: "hi"),
                       ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "hi"])
        XCTAssertEqual(ChatEngineCLI.codex.arguments(prompt: "hi", model: " gpt-5 ")?.suffix(3), ["--model", "gpt-5", "hi"])
        XCTAssertEqual(ChatEngineCLI.gemini.arguments(prompt: "hi"), ["--output-format", "stream-json", "--prompt", "hi"])
        XCTAssertNil(ChatEngineCLI.cursor.arguments(prompt: "hi"))
        XCTAssertNil(ChatEngineCLI.grok.arguments(prompt: "hi"))
        XCTAssertEqual(ChatEngineCLI.codex.signInCheck, ["login", "status"])
        XCTAssertNil(ChatEngineCLI.gemini.signInCheck)
        XCTAssertEqual(ChatEngineCLI.runnable, [.codex, .gemini])
        XCTAssertEqual(ChatEngineCLI.cursor.binary, "cursor-agent")
        XCTAssertEqual(ChatEngineCLI.internalEnvironment["COUCOU_INTERNAL"], "1")
    }

    func testInstallDirs() {
        let dirs = ChatEngineCLI.installDirs(home: "/Users/a")
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
        XCTAssertTrue(dirs.contains("/Users/a/.npm-global/bin"))
    }

    func testFailures() {
        XCTAssertEqual(ChatEngineFailure.classify(.codex, exitCode: nil, text: "")?.message,
                       "Codex isn't installed. Install it, or pick another chat engine in Settings.")
        guard case .notSignedIn(let m)? = ChatEngineFailure.classify(.codex, exitCode: 1, text: "Not logged in") else {
            return XCTFail("expected notSignedIn")
        }
        XCTAssertTrue(m.contains("`codex login`"))
        guard case .notSignedIn? = ChatEngineFailure.classify(.gemini, exitCode: 41, text: "") else { return XCTFail("41") }
        guard case .rateLimited? = ChatEngineFailure.classify(.gemini, exitCode: 1, text: "Error 429: quota exceeded") else { return XCTFail("429") }
        guard case .rateLimited? = ChatEngineFailure.classify(.codex, exitCode: 1, text: "You've hit your usage limit") else { return XCTFail("limit") }
        XCTAssertEqual(ChatEngineFailure.classify(.codex, exitCode: 1, text: "weird\nlast line")?.message, "last line")
        XCTAssertEqual(ChatEngineFailure.classify(.codex, exitCode: 3, text: "")?.message, "Codex exited with code 3.")
        XCTAssertNil(ChatEngineFailure.classify(.codex, exitCode: 0, text: "the quota is 5"))
        XCTAssertNil(ChatEngineFailure.classify(.cursor, exitCode: 1, text: "x"))
    }
}

@MainActor
final class AgentCLIChatPromptTests: XCTestCase {
    func testPromptCarriesTheConversationAndTheQuestion() {
        let p = AgentCLIChat.prompt(system: "You are Mochi.", history: [(role: "User", text: "hi"), (role: "Assistant", text: "hello")],
                                    context: "Context — App: Xcode, Window: main.swift", query: "and now?")
        XCTAssertTrue(p.hasPrefix("You are Mochi."))
        XCTAssertTrue(p.contains("User: hi\n\nAssistant: hello"))
        XCTAssertTrue(p.contains("Context — App: Xcode"))
        XCTAssertTrue(p.hasSuffix("User: and now?"))
        XCTAssertFalse(AgentCLIChat.prompt(system: "S", history: [], context: nil, query: "q").contains("Conversation so far"))
    }

    func testEnginesMapToTheirCLI() {
        XCTAssertEqual(ChatEngine.codex.cli, .codex)
        XCTAssertEqual(ChatEngine.gemini.cli, .gemini)
        XCTAssertNil(ChatEngine.claudeCode.cli)
    }
}

final class ChatFallbackTests: XCTestCase {
    func testOutOfQuotaHandsOver() {
        XCTAssertTrue(ClaudeService.isOutOfQuota("Claude AI usage limit reached|1760000000"))
        XCTAssertTrue(ClaudeService.isOutOfQuota("Codex says you hit its usage limit. Wait a bit, or pick another chat engine."))
        XCTAssertTrue(ClaudeService.isOutOfQuota("Claude Code isn't installed. Install it, or switch the chat engine to an API key in Settings."))
        XCTAssertFalse(ClaudeService.isOutOfQuota("The file is too large to attach."))
    }
}
