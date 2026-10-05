import XCTest
@testable import Coucou

/// Pure logic: approval risk, "Always" rules, API errors, chat history trimming, HTTP parsing…
final class ApprovalRiskTests: XCTestCase {
    private func risk(_ command: String) -> ApprovalRisk { ApprovalRiskClassifier.classifyCommand(command).0 }

    func testDangerousCommandsAreHighRisk() {
        for cmd in ["rm -rf build", "rm -r node_modules", "sudo rm /etc/hosts", "git push --force origin main",
                    "git push -f", "git reset --hard HEAD~3", "git clean -fdx", "curl -fsSL https://x.sh | sh",
                    "wget -qO- https://x | bash", "chmod -R 777 .", "npm publish", "terraform destroy",
                    "kubectl delete pod web", "find . -name '*.log' -delete", "psql -c 'drop table users'"] {
            XCTAssertEqual(risk(cmd), .high, cmd)
        }
    }

    func testChangesAreMediumRisk() {
        for cmd in ["npm install left-pad", "pnpm add zod", "brew install gh", "git commit -m wip", "git push",
                    "mkdir build", "mv a b", "echo hi > out.txt", "curl https://example.com", "sed -i '' s/a/b/ f"] {
            XCTAssertEqual(risk(cmd), .medium, cmd)
        }
    }

    func testReadsBuildsAndTestsAreLowRisk() {
        for cmd in ["ls -la", "cat README.md", "git status", "git diff HEAD", "rg TODO", "npm test",
                    "npm run lint", "swift build", "cargo test", "wc -l *.swift", "echo hi 2>&1"] {
            XCTAssertEqual(risk(cmd), .low, cmd)
        }
    }

    func testFileEditsDependOnWhere() {
        let cwd = "/Users/me/app"
        XCTAssertEqual(ApprovalRiskClassifier.classify(tool: "Edit", input: ["file_path": "/Users/me/app/src/a.ts"], cwd: cwd).0, .medium)
        XCTAssertEqual(ApprovalRiskClassifier.classify(tool: "Write", input: ["file_path": "/Users/me/app/.env"], cwd: cwd).0, .high)
        XCTAssertEqual(ApprovalRiskClassifier.classify(tool: "Edit", input: ["file_path": "/Users/me/other/x.ts"], cwd: cwd).0, .high)
        XCTAssertEqual(ApprovalRiskClassifier.classify(tool: "Read", input: [:], cwd: cwd).0, .low)
        XCTAssertEqual(ApprovalRiskClassifier.classify(tool: "mcp__linear__save_issue", input: [:], cwd: cwd).0, .medium)
    }
}

final class ApprovalRulesTests: XCTestCase {
    func testDescribesRulesAndWhereTheyAreSaved() {
        let lines = ApprovalRules.describe([
            ["type": "addRules", "behavior": "allow", "destination": "localSettings",
             "rules": [["toolName": "Bash", "ruleContent": "npm run test:*"], ["toolName": "WebFetch"]]],
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
        ])
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("Bash(npm run test:*)"))
        XCTAssertTrue(lines[1].contains("WebFetch"))
        XCTAssertTrue(lines[2].contains("acceptEdits"))
    }

    func testNoSuggestionsMeansNoAlwaysButton() {
        XCTAssertTrue(ApprovalRules.describe([]).isEmpty)
    }
}

final class APIErrorTests: XCTestCase {
    private func message(_ status: Int, _ type: String, _ text: String = "") -> String {
        let body = try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": text]])
        return APIError(status: status, body: body, model: "claude-test-1").message
    }

    func testErrorsAreExplained() {
        XCTAssertTrue(message(401, "authentication_error").contains("API key"))
        XCTAssertTrue(message(404, "not_found_error", "model: claude-test-1").contains("claude-test-1"))
        XCTAssertTrue(message(400, "invalid_request_error", "Your credit balance is too low").lowercased().contains("credit"))
        XCTAssertTrue(message(529, "overloaded_error").lowercased().contains("overloaded"))
        XCTAssertEqual(message(400, "invalid_request_error", "messages: bad"), "messages: bad")
    }

    func testOfflineIsPlainWords() {
        XCTAssertTrue(APIError.describe(URLError(.notConnectedToInternet)).lowercased().contains("internet"))
    }
}

@MainActor
final class ChatHistoryTrimTests: XCTestCase {
    private func turns(_ n: Int) -> [[String: Any]] {
        (0..<n).map { ["role": $0 % 2 == 0 ? "user" : "assistant", "content": "m\($0)"] }
    }

    func testShortChatsAreSentWhole() {
        XCTAssertEqual(ClaudeService.trimmed(turns(9)).count, 9)
    }

    func testLongChatsKeepTheFirstExchangeAndTheLatestTurns() {
        let sent = ClaudeService.trimmed(turns(41))
        XCTAssertEqual(sent.count, 2 + ClaudeService.maxRecentMessages)
        XCTAssertEqual(sent[0]["content"] as? String, "m0")
        XCTAssertEqual(sent[2]["role"] as? String, "user", "turns must keep alternating")
        XCTAssertEqual(sent.last?["content"] as? String, "m40")
    }

    func testCacheBreakpointGoesOnTheLastBlockOnly() {
        let marked = ClaudeService.withCacheBreakpoint([
            ["role": "user", "content": [["type": "text", "text": "a"]]],
            ["role": "assistant", "content": "b"],
            ["role": "user", "content": [["type": "document", "source": [:]], ["type": "text", "text": "c"]]],
        ])
        let last = marked.last?["content"] as? [[String: Any]]
        XCTAssertNotNil(last?.last?["cache_control"])
        XCTAssertNil(last?.first?["cache_control"])
        XCTAssertNil((marked.first?["content"] as? [[String: Any]])?.first?["cache_control"])
    }
}

final class GitHubHTTPTests: XCTestCase {
    func testSplitsStatusHeadersAndBody() {
        let raw = "HTTP/2.0 200 OK\r\nEtag: W/\"abc\"\r\nX-Ratelimit-Remaining: 59\r\n\r\n{\"login\":\"me\"}"
        let r = GitHubHTTP.split(Data(raw.utf8))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["etag"], "W/\"abc\"")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"login\":\"me\"}")
    }

    func testNotModified() {
        XCTAssertEqual(GitHubHTTP.split(Data("HTTP/2.0 304 Not Modified\n\n".utf8)).status, 304)
    }
}

final class PollGateTests: XCTestCase {
    private func response(_ code: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    func testBacksOffAfterErrorsAndRecovers() {
        let id = "test-\(UUID().uuidString)"
        XCTAssertTrue(PollGate.shared.allow(id, every: 30))
        PollGate.shared.record(id, response(500))
        XCTAssertFalse(PollGate.shared.allow(id, every: 30), "waits after an error")
        PollGate.shared.manual(id)
        XCTAssertTrue(PollGate.shared.allow(id, every: 30), "a manual refresh clears the backoff")
    }

    func testHonoursRetryAfter() {
        let id = "test-\(UUID().uuidString)"
        _ = PollGate.shared.allow(id, every: 1)
        PollGate.shared.record(id, response(429, headers: ["Retry-After": "3600"]))
        XCTAssertFalse(PollGate.shared.allow(id, every: 1))
    }
}

final class EditorContextTests: XCTestCase {
    func testFileNameFromWindowTitles() {
        XCTAssertEqual(CodeContextCapture.fileName(fromTitle: "● cart.ts — shopit"), "cart.ts")
        XCTAssertEqual(CodeContextCapture.fileName(fromTitle: "cart.ts - shopit - Visual Studio Code"), "cart.ts")
        XCTAssertNil(CodeContextCapture.fileName(fromTitle: "Welcome"))
    }

    func testEditPreviewShowsTheChange() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).ts")
        try "let a = 1\nconst TVA = 0.196\nlet b = 2\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let preview = EditPreviewBuilder.build(tool: "Edit", input: [
            "file_path": file.path, "old_string": "const TVA = 0.196", "new_string": "const TVA = 0.20"],
            cwd: file.deletingLastPathComponent().path)
        let lines = try XCTUnwrap(preview).lines
        XCTAssertTrue(lines.contains { $0.kind == .removed && $0.text.contains("0.196") })
        XCTAssertTrue(lines.contains { $0.kind == .added && $0.text.contains("0.20") })
    }
}

@MainActor
final class TimelineTests: XCTestCase {
    func testRecordsStepsWithDurationsAndApprovals() {
        let s = "test-\(UUID().uuidString)"
        let store = TimelineStore.shared
        store.record(event: "UserPromptSubmit", sessionId: s, payload: ["prompt": "fix the tests"])
        store.record(event: "PreToolUse", sessionId: s, payload: ["tool_name": "Read", "tool_use_id": "1",
                                                                   "tool_input": ["file_path": "/p/a.ts"]])
        store.record(event: "PostToolUse", sessionId: s, payload: ["tool_name": "Read", "tool_use_id": "1"])
        store.record(event: "PreToolUse", sessionId: s, payload: ["tool_name": "Bash", "tool_use_id": "2",
                                                                   "tool_input": ["command": "npm test"]])
        store.record(event: "PostToolUseFailure", sessionId: s, payload: ["tool_name": "Bash", "tool_use_id": "2"])
        store.recordApproval(ApprovalInfo(sessionId: s, tool: "Bash", command: "rm -rf build"), decision: "deny")
        store.record(event: "Stop", sessionId: s, payload: [:])

        let list = store.entries[s] ?? []
        XCTAssertEqual(list.map(\.kind), [.prompt, .read, .command, .approval, .done])
        XCTAssertNotNil(list[1].duration)
        XCTAssertEqual(list[1].detail, "a.ts")
        XCTAssertTrue(list[2].failed)
        XCTAssertTrue(list[3].failed, "a denial is marked")
        XCTAssertTrue(store.markdown(s, project: "p").contains("npm test"))
    }
}

final class EditorContextPreambleTests: XCTestCase {
    func testExtensionDetailsReachThePrompt() {
        let context = CodeContext(appName: "Cursor", file: "/p/src/cart.ts", project: "/p", selection: nil,
                                  cursorLine: 42, problems: ["line 42 · error (ts): Cannot find name 'totl'"])
        XCTAssertTrue(context.promptPreamble.contains("line 42"))
        XCTAssertTrue(context.promptPreamble.contains("Cannot find name"))
        XCTAssertTrue(context.inlinePreamble.contains("Cannot find name"))
        XCTAssertEqual(context.relativePath, "src/cart.ts")
    }

    func testOldSavedChatsWithoutTheNewFieldsStillLoad() throws {
        let json = #"{"appName":"VS Code","file":"/p/a.ts","project":"/p"}"#
        let context = try JSONDecoder().decode(CodeContext.self, from: Data(json.utf8))
        XCTAssertNil(context.cursorLine)
        XCTAssertNil(context.problems)
    }
}

final class AutoApproveTests: XCTestCase {
    func testLevelsNeverAllowHighRisk() {
        XCTAssertFalse(AutoApproveLevel.ask.allows(.low))
        XCTAssertTrue(AutoApproveLevel.low.allows(.low))
        XCTAssertFalse(AutoApproveLevel.low.allows(.medium))
        XCTAssertTrue(AutoApproveLevel.medium.allows(.medium))
        for level in AutoApproveLevel.allCases { XCTAssertFalse(level.allows(.high)) }
    }

    @MainActor
    func testHighRiskAndChatAlwaysAsk() {
        XCTAssertFalse(AutoApprove.shouldAllow(risk: .high, cwd: "/any", fromChat: false))
        XCTAssertFalse(AutoApprove.shouldAllow(risk: .low, cwd: "/any", fromChat: true))
        XCTAssertFalse(AutoApprove.shouldAllow(risk: .low, cwd: "", fromChat: false))
    }
}

final class LinearTests: XCTestCase {
    func testIssueIdentifiersFromBranchNames() {
        XCTAssertEqual(LinearLink.identifiers(inBranch: "wolfgang/sho-123-fix-cart"), ["SHO-123"])
        XCTAssertEqual(LinearLink.identifiers(inBranch: "SHO-42"), ["SHO-42"])
        XCTAssertEqual(LinearLink.identifiers(inBranch: "feature/eng-7_new-login"), ["ENG-7"])
        XCTAssertEqual(LinearLink.identifiers(inBranch: "main"), [])
        XCTAssertEqual(LinearLink.identifiers(inBranch: "release/2026-10"), [], "a year isn't an issue")
    }

    func testParsesAnIssueNode() throws {
        let issue = try XCTUnwrap(LinearIssue([
            "id": "uuid", "identifier": "SHO-123", "title": "Fix cart", "url": "https://linear.app/x/issue/SHO-123",
            "branchName": "wolfgang/sho-123-fix-cart", "priority": 2, "updatedAt": "2026-10-01T12:00:00.000Z",
            "state": ["name": "In Progress", "type": "started", "color": "#f2c94c"],
        ]))
        XCTAssertEqual(issue.identifier, "SHO-123")
        XCTAssertEqual(issue.stateType, "started")
        XCTAssertNotNil(issue.updatedAt)
    }
}

final class InboxTests: XCTestCase {
    func testGitHubAPILinksBecomeWebLinks() {
        XCTAssertEqual(GitHubInbox.webURL("https://api.github.com/repos/rouderz/coucou/pulls/80"),
                       "https://github.com/rouderz/coucou/pull/80")
        XCTAssertEqual(GitHubInbox.webURL("https://api.github.com/repos/rouderz/coucou/issues/12"),
                       "https://github.com/rouderz/coucou/issues/12")
        XCTAssertNil(GitHubInbox.webURL(nil))
    }
}

final class DataPillsTests: XCTestCase {
    func testBuildTimeFormatting() {
        let d = VercelDeployment(id: "1", projectName: "web", url: "", state: "READY", createdAt: .now,
                                 commitMessage: nil, branch: nil, buildSeconds: 72)
        XCTAssertEqual(d.buildTime, "1m 12s")
        XCTAssertNil(VercelDeployment(id: "2", projectName: "web", url: "", state: "READY", createdAt: .now,
                                      commitMessage: nil, branch: nil).buildTime)
    }
}

@MainActor
final class ProviderTests: XCTestCase {
    func testPresetsAreComplete() {
        let ids = ProviderPreset.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("ollama"))
        XCTAssertFalse(ProviderPreset.find("ollama").needsKey)
        XCTAssertEqual(ProviderPreset.find("nope").id, "openai", "unknown ids fall back to the first preset")
    }

    func testErrorsAreExplained() {
        XCTAssertTrue(OpenAICompatibleChat.error(code: 401, data: Data(), model: "m").message.contains("API key"))
        XCTAssertTrue(OpenAICompatibleChat.error(code: 404, data: Data(), model: "gpt-x").message.contains("gpt-x"))
        let body = Data(#"{"error":{"message":"context too long"}}"#.utf8)
        XCTAssertEqual(OpenAICompatibleChat.error(code: 400, data: body, model: "m").message, "context too long")
    }
}

@MainActor
final class WakeWordTests: XCTestCase {
    func testWakePhrasesAndCleanup() {
        XCTAssertTrue(WakeWord.phrases.contains("hey mochi"))
        XCTAssertTrue(WakeWord.phrases.contains("oye mochi"))
        XCTAssertEqual(WakeWord.clean(", what's on my calendar? "), "what's on my calendar")
        XCTAssertEqual(WakeWord.clean("  "), "")
    }
}

@MainActor
final class UpdatesTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updates.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(Updates.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(Updates.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(Updates.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(Updates.isNewer("0.1.9", than: "0.2.0"))
    }

    func testParsesALatestRelease() throws {
        let json = """
        {"tag_name":"v0.3.0","html_url":"https://github.com/rouderz/coucou/releases/tag/v0.3.0","draft":false,
         "prerelease":false,"body":"Notes","published_at":"2026-10-02T10:00:00Z",
         "assets":[{"name":"Coucou-0.3.0.dmg","browser_download_url":"https://github.com/x/Coucou-0.3.0.dmg"}]}
        """
        let r = try XCTUnwrap(Updates.parse(Data(json.utf8)))
        XCTAssertEqual(r.version, "0.3.0")
        XCTAssertEqual(r.dmgURL, "https://github.com/x/Coucou-0.3.0.dmg")
        XCTAssertNil(Updates.parse(Data(#"{"tag_name":"v9","prerelease":true}"#.utf8)), "pre-releases are ignored")
    }
}

/// Codex CLI (#44): apply_patch parsing, risk, approval text and the hooks.json installer.
final class CodexTests: XCTestCase {
    private let patch = """
    *** Begin Patch
    *** Update File: src/app.ts
    @@ function main
     const a = 1
    -const b = 2
    +const b = 3
    *** Add File: src/new.ts
    +export const x = 1
    *** End Patch
    """

    func testParsesFilesAndLines() {
        let changes = CodexPatch.parse(patch)
        XCTAssertEqual(changes.map(\.path), ["src/app.ts", "src/new.ts"])
        XCTAssertEqual(changes[0].kind, .update)
        XCTAssertEqual(changes[1].kind, .add)
        XCTAssertEqual(changes[0].lines.map(\.kind), [.context, .removed, .added])
        XCTAssertEqual(changes[0].lines.last?.text, "const b = 3")
    }

    func testPreviewShowsTheFirstFile() {
        let preview = EditPreviewBuilder.build(tool: "apply_patch", input: ["command": patch], cwd: "/p")
        XCTAssertEqual(preview?.file, "/p/src/app.ts")
        XCTAssertEqual(preview?.lines.count, 3)
        XCTAssertNotNil(preview?.note, "mentions the other file")
    }

    func testPatchRiskFollowsTheFiles() {
        XCTAssertEqual(ApprovalRiskClassifier.classify(tool: "apply_patch", input: ["command": patch], cwd: "/p").0, .medium)
        let env = "*** Begin Patch\n*** Update File: .env\n+KEY=1\n*** End Patch"
        XCTAssertEqual(ApprovalRiskClassifier.classify(tool: "apply_patch", input: ["command": env], cwd: "/p").0, .high)
    }

    func testApprovalTextAndStopMessage() {
        XCTAssertEqual(HookServer.approvalCommand(tool: "apply_patch", input: ["command": patch]),
                       "Edit src/app.ts, src/new.ts")
        XCTAssertEqual(HookServer.approvalCommand(tool: "Bash", input: ["description": "Run tests"]), "Run tests")
        XCTAssertEqual(HookServer.stopMessage(["last_assistant_message": "All done"]), "All done")
        XCTAssertNil(HookServer.stopMessage(["message": ""]))
    }

    func testInstallKeepsTheUsersHooks() throws {
        let mine: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash",
                                                            "hooks": [["type": "command", "command": "my-policy"]]]]]]
        let installed = CodexHooks.installed(into: mine, command: "\"/x/nb-hook\" --agent codex")
        let pre = (installed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 2)
        // Installing twice doesn't duplicate.
        let again = CodexHooks.installed(into: installed, command: "\"/x/nb-hook\" --agent codex")
        XCTAssertEqual(((again["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.count, 2)
        let perm = ((again["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first
        XCTAssertEqual(((perm?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int), 120)

        let removed = CodexHooks.uninstalled(from: again)
        let hooks = removed["hooks"] as? [String: Any]
        XCTAssertEqual(hooks?.keys.sorted(), ["PreToolUse"])
        XCTAssertEqual((hooks?["PreToolUse"] as? [[String: Any]])?.count, 1)
    }
}

/// Ports (#17): secrets, integrations and agents behind one interface each.
@MainActor
final class PortsTests: XCTestCase {
    func testInMemorySecrets() {
        let store = InMemorySecretStore(["a": "1"])
        XCTAssertEqual(store.get("a"), "1")
        store.set("b", value: "2")
        store.remove("a")
        XCTAssertNil(store.get("a"))
        XCTAssertEqual(store.get("b"), "2")
    }

    func testEveryCardHasOneIntegration() {
        let ids = Integrations.all.map(\.integrationID)
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicates")
        for id in ["integration_github", "integration_linear", "integration_stripe", "integration_claude", "integration_ci"] {
            XCTAssertNotNil(Integrations.source(id), id)
        }
        XCTAssertNil(Integrations.source("integration_nope"))
    }

    func testAgentsByEventTag() {
        XCTAssertEqual(Agents.named("claude")?.name, "Claude Code")
        XCTAssertEqual(Agents.named("codex")?.name, "Codex")
        XCTAssertNil(Agents.named("other"))
    }
}

/// Chat port (#16): every engine behind ChatProvider, with what it can do.
@MainActor
final class ChatPortTests: XCTestCase {
    func testEachEngineHasItsAdapter() {
        XCTAssertTrue(ClaudeService.provider(for: .claudeCode) === ClaudeCodeChat.shared)
        XCTAssertTrue(ClaudeService.provider(for: .apiKey) === AnthropicAPIChat.shared)
        XCTAssertTrue(ClaudeService.provider(for: .provider) === OpenAICompatibleChat.shared)
    }

    func testOnlyClaudeCodeEditsFiles() {
        XCTAssertTrue(ClaudeCodeChat.shared.capabilities.contains(.editsFiles))
        XCTAssertFalse(AnthropicAPIChat.shared.capabilities.contains(.editsFiles))
        XCTAssertFalse(OpenAICompatibleChat.shared.capabilities.contains(.editsFiles))
        XCTAssertTrue(AnthropicAPIChat.shared.capabilities.contains(.webSearch))
    }

    func testAPIContextGoesOnTheFirstTurnOnly() {
        let chat = AnthropicAPIChat.shared
        chat.reset()
        let request = ChatRequest(query: "what is this?", context: .window(appName: "Safari", title: "Docs", url: nil),
                                  systemPrompt: "")
        let first = chat.userContent(for: request)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.last?["text"] as? String, "what is this?")

        chat.restore([.init(user: true, text: "hi"), .init(user: false, text: "hello")])
        XCTAssertEqual(chat.userContent(for: request).count, 1, "later turns: just the question")
        chat.reset()
    }

    func testRestoreEndsOnAnAnswer() {
        let chat = AnthropicAPIChat.shared
        chat.restore([.init(user: true, text: "a"), .init(user: false, text: "b"), .init(user: true, text: "c")])
        XCTAssertEqual(chat.messages.count, 2)
        chat.reset()
    }
}
