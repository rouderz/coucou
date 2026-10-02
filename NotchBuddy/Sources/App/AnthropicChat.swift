import Foundation

// MARK: - Anthropic adapters for the ChatProvider port (#16)

/// Anthropic Messages API with the key from Settings: web search, attachments, prompt caching.
@MainActor
final class AnthropicAPIChat: ChatProvider {
    static let shared = AnthropicAPIChat()

    let capabilities: ChatCapabilities = [.webSearch, .attachments, .needsKey]

    /// Messages in API format; the assistant turns keep their tool use and search results.
    private(set) var messages: [[String: Any]] = []
    var turn: Int { messages.count / 2 }

    private let webSearchTools: [[String: Any]] = [
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 5]
    ]

    func reset() { messages = [] }

    /// Continues a saved conversation from its text (attachments aren't kept).
    func restore(_ saved: [SavedChat.Message]) {
        messages = saved.map { m -> [String: Any] in
            ["role": m.user ? "user" : "assistant", "content": [["type": "text", "text": m.text]]]
        }
        // The API needs user/assistant turns to alternate and to end on an answer.
        while let last = messages.last, last["role"] as? String == "user" { messages.removeLast() }
    }

    /// The user turn: window/file/code context goes in on the first message only.
    func userContent(for request: ChatRequest) -> [[String: Any]] {
        var content: [[String: Any]] = []
        if messages.isEmpty, let context = request.context {
            switch context {
            case .window(let app, let title, let url):
                var text = "Context — App: \(app), Window: \(title)"
                if let url { text += ", URL: \(url)" }
                content.append(["type": "text", "text": text])
            case .file(let name, let fileURL):
                if let fileURL, let block = ClaudeService.shared.readFileAsBlock(url: fileURL) {
                    content.append(block)
                }
                content.append(["type": "text", "text": "File: \(name)"])
            case .code(let code):
                if let block = ClaudeService.shared.readFileAsBlock(url: URL(fileURLWithPath: code.file)) {
                    content.append(block)
                }
                content.append(["type": "text", "text": code.inlinePreamble])
            }
        }
        content.append(["type": "text", "text": request.query])
        return content
    }

    /// Streams the answer. Web search may pause the turn (`pause_turn`); the paused message is
    /// sent back so Claude finishes it, up to 4 times.
    func stream(_ request: ChatRequest, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let key = ClaudeService.shared.apiKey, !key.isEmpty else {
            throw APIError(message: L("API key missing. Open settings."))
        }
        messages.append(["role": "user", "content": userContent(for: request)])
        do {
            var content: [[String: Any]] = []
            for _ in 0..<4 {
                var turnMessages = ClaudeService.trimmed(messages)
                if !content.isEmpty { turnMessages.append(["role": "assistant", "content": content]) }
                let body: [String: Any] = [
                    "model": ClaudeService.shared.currentModel,
                    "max_tokens": AppState.shared.apiMaxTokens,
                    "tools": webSearchTools,
                    // Cached: the system prompt and everything up to the newest message (attachments
                    // included) are billed at ~10% on the next turns instead of being resent in full.
                    "system": [["type": "text", "text": request.systemPrompt, "cache_control": ["type": "ephemeral"]]],
                    "messages": ClaudeService.withCacheBreakpoint(turnMessages),
                    "stream": true,
                ]
                let before = ClaudeService.text(of: content)
                let part = try await ClaudeService.shared.streamMessage(
                    body: body, key: key, beta: "web-search-2025-03-05", kind: "chat") { onText(before + $0) }
                content += part.content
                if part.stopReason != "pause_turn" { break }
            }
            let answer = ClaudeService.text(of: content).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                throw APIError(message: L("Claude didn't write an answer. Try asking again."))
            }
            // Full content (tool use + search results) keeps the next turns grounded.
            messages.append(["role": "assistant", "content": content])
            return answer
        } catch {
            // Drop the unanswered question so the conversation stays valid for the next try.
            if messages.last?["role"] as? String == "user" { messages.removeLast() }
            throw error
        }
    }
}

/// The user's own Claude Code CLI (subscription): it can also read and, if allowed, edit the project.
extension ClaudeCodeChat: ChatProvider {
    var capabilities: ChatCapabilities { [.webSearch, .attachments, .editsFiles] }

    func stream(_ request: ChatRequest, onText: @escaping @MainActor (String) -> Void) async throws -> String {
        try await send(query: request.query, context: request.context, model: ClaudeService.shared.currentModel,
                       systemPrompt: request.systemPrompt, onText: onText)
    }

    /// Saved chats resume through their Claude Code session (`restore(sessionID:…)`), not their text.
    func restore(_ messages: [SavedChat.Message]) {}

    /// Claude Code's own errors are already written for the user.
    func describe(_ error: Error) -> String { error.localizedDescription }
}
