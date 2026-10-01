import Foundation
import OSLog
import Security

// MARK: - Keychain helpers

enum Keychain {
    static let service = "fr.louisraille.NotchBuddy"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete existing item first (update pattern)
        let lookup: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(lookup as CFDictionary)
        // Add with strictest access control:
        // WhenUnlockedThisDeviceOnly = accessible only while Mac is unlocked,
        // never synced to iCloud, never migrated to another device.
        let item: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Keychain cache (reads each key ONCE at launch; all subsequent access via dict)

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let allKeys = [
        "anthropic-api-key",
        "resend-api-key", "resend-from",
        "n8n-url", "n8n-api-key",
        "vercel-token",
        "github-token",
        "stripe-api-key",
        "calcom-api-key",
        "notion-api-key",
    ]

    private init() {
        // Called once, on main thread (AppDelegate triggers shared at launch).
        for key in Self.allKeys {
            if let v = Keychain.load(key: key) { cache[key] = v }
        }
    }

    /// Thread-safe read — never touches the Keychain.
    func get(_ key: String) -> String? {
        lock.withLock { cache[key] }
    }

    /// Updates cache + persists to Keychain.
    func set(_ key: String, value: String) {
        lock.withLock { cache[key] = value }
        Keychain.save(key: key, value: value)
    }

    /// Removes from cache + Keychain only if the key was previously set.
    func remove(_ key: String) {
        let had = lock.withLock { () -> Bool in
            let exists = cache[key] != nil
            cache[key] = nil
            return exists
        }
        if had { Keychain.delete(key: key) }
    }
}

/// Per-request token usage, readable with `scripts/measure-baseline.sh tokens`.
private let claudeLog = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")

// MARK: - Claude API

@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    /// Chosen in Settings; falls back to the default when the field is left empty.
    private var model: String {
        let m = AppState.shared.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? AppState.defaultClaudeModel : m
    }

    var apiKey: String? { KeychainStore.shared.get("anthropic-api-key") }

    // Multi-turn conversation messages (for API)
    private var conversationMessages: [[String: Any]] = []

    func clearConversation() {
        conversationMessages = []
    }

    /// API engine: continues a saved conversation from its text (attachments aren't kept).
    func restoreConversation(_ messages: [SavedChat.Message]) {
        conversationMessages = messages.map { m -> [String: Any] in
            ["role": m.user ? "user" : "assistant", "content": [["type": "text", "text": m.text]]]
        }
        // The API needs user/assistant turns to alternate and to end on an answer.
        while let last = conversationMessages.last, last["role"] as? String == "user" {
            conversationMessages.removeLast()
        }
    }

    static let systemPrompt = """
    You are Mochi, a personal AI assistant living in the notch of the user's Mac. \
    You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
    Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
    No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.
    """

    private let webSearchTools: [[String: Any]] = [
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 5]
    ]

    // MARK: - Chat (multi-turn, natural text + web search)

    func chat(query: String, context: PromptContext?, state: AppState) async {
        if state.chatEngine == .claudeCode {
            await chatWithClaudeCode(query: query, context: context, state: state)
            return
        }
        guard let key = apiKey, !key.isEmpty else {
            await showError("API key missing. Open settings.", state: state)
            return
        }

        // Build user content for this turn
        var userContent: [[String: Any]] = []

        // Add file/window context on first message only
        if conversationMessages.isEmpty, let context = context {
            switch context {
            case .window(let app, let title, let url):
                var text = "Context — App: \(app), Window: \(title)"
                if let url = url { text += ", URL: \(url)" }
                userContent.append(["type": "text", "text": text])
            case .file(let name, let fileURL):
                if let fileURL = fileURL, let block = readFileAsBlock(url: fileURL) {
                    userContent.append(block)
                }
                userContent.append(["type": "text", "text": "File: \(name)"])
            case .code(let code):
                if let block = readFileAsBlock(url: URL(fileURLWithPath: code.file)) {
                    userContent.append(block)
                }
                userContent.append(["type": "text", "text": code.inlinePreamble])
            }
        }
        userContent.append(["type": "text", "text": query])

        conversationMessages.append(["role": "user", "content": userContent])

        do {
            try await streamChat(key: key, state: state)
        } catch {
            // Drop the unanswered question so the conversation stays valid for the next try.
            if conversationMessages.last?["role"] as? String == "user" { conversationMessages.removeLast() }
            VoiceOutput.shared.stop()
            await showError(APIError.describe(error), state: state)
        }
    }

    /// API engine: streams the answer into the chat as it's written. Web search may pause the turn
    /// (`pause_turn`); the paused message is sent back so Claude finishes it, up to 4 times.
    private func streamChat(key: String, state: AppState) async throws {
        var replyID: UUID?
        func show(_ text: String) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            if let id = replyID, let i = state.chatHistory.firstIndex(where: { $0.id == id }) {
                state.chatHistory[i].content = clean
            } else {
                let msg = ChatMessage(role: .assistant, content: clean)
                replyID = msg.id
                state.chatHistory.append(msg)
                state.stateOverride = nil  // hide the typing dots once text streams in
            }
            VoiceOutput.shared.feed(clean)
        }

        var content: [[String: Any]] = []
        for _ in 0..<4 {
            var messages = Self.trimmed(conversationMessages)
            if !content.isEmpty { messages.append(["role": "assistant", "content": content]) }
            let body: [String: Any] = [
                "model": model,
                "max_tokens": AppState.shared.apiMaxTokens,
                "tools": webSearchTools,
                // Cached: the system prompt and everything up to the newest message (attachments
                // included) are billed at ~10% on the next turns instead of being resent in full.
                "system": [["type": "text", "text": Self.systemPrompt, "cache_control": ["type": "ephemeral"]]],
                "messages": Self.withCacheBreakpoint(messages),
                "stream": true,
            ]
            let before = Self.text(of: content)
            let part: (content: [[String: Any]], stopReason: String?)
            do {
                part = try await streamMessage(body: body, key: key, beta: "web-search-2025-03-05",
                                               kind: "chat") { show(before + $0) }
            } catch {
                if let id = replyID { state.chatHistory.removeAll { $0.id == id } }
                throw error
            }
            content += part.content
            if part.stopReason != "pause_turn" { break }
        }

        let answer = Self.text(of: content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            if let id = replyID { state.chatHistory.removeAll { $0.id == id } }
            throw APIError(message: "Claude didn't write an answer. Try asking again.")
        }
        // Full content (tool use + search results) keeps the next turns grounded.
        conversationMessages.append(["role": "assistant", "content": content])
        show(answer)
        VoiceOutput.shared.finish(answer)
        ChatStore.shared.saveCurrent(state)
        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    // MARK: - Chat through the user's Claude Code (subscription)

    private func chatWithClaudeCode(query: String, context: PromptContext?, state: AppState) async {
        let engine = ClaudeCodeChat.shared
        // The chat view only holds the new question: a fresh conversation.
        if state.chatHistory.count <= 1 { engine.reset() }

        var replyID: UUID?
        func show(_ text: String) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            if let id = replyID, let i = state.chatHistory.firstIndex(where: { $0.id == id }) {
                state.chatHistory[i].content = clean
                VoiceOutput.shared.feed(clean)
            } else {
                let msg = ChatMessage(role: .assistant, content: clean)
                replyID = msg.id
                state.chatHistory.append(msg)
                state.stateOverride = nil  // hide the typing dots once text streams in
            }
        }

        do {
            let answer = try await engine.send(query: query, context: context, model: model,
                                               systemPrompt: Self.systemPrompt) { partial in show(partial) }
            show(answer)
            VoiceOutput.shared.finish(answer.trimmingCharacters(in: .whitespacesAndNewlines))
            state.stateOverride = nil
            state.view = .prompt
            ChatStore.shared.saveCurrent(state)
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            if let id = replyID { state.chatHistory.removeAll { $0.id == id } }
            VoiceOutput.shared.stop()
            await showError(error.localizedDescription, state: state)
        }
    }

    // MARK: - Structured search (M8 — window attach + web search)

    func search(query: String, context: PromptContext?, state: AppState) async {
        guard let key = apiKey, !key.isEmpty else {
            await showError("Anthropic API key missing. Open settings to configure it.", state: state)
            return
        }

        var userContent: [[String: Any]] = []
        switch context {
        case .window(let appName, let title, let url):
            var text = "App: \(appName)\nWindow title: \(title)"
            if let url = url { text += "\nURL: \(url)" }
            text += "\n\nRequest: \(query)"
            userContent.append(["type": "text", "text": text])
        case .file(let name, let fileURL):
            if let fileURL = fileURL, let fileBlock = readFileAsBlock(url: fileURL) {
                userContent.append(fileBlock)
            }
            userContent.append(["type": "text", "text": "File: \(name)\n\nRequest: \(query)"])
        case .code(let code):
            if let block = readFileAsBlock(url: URL(fileURLWithPath: code.file)) {
                userContent.append(block)
            }
            var text = "File: \(code.relativePath) (project \(code.projectName))"
            if let sel = code.selection { text += "\nSelected text:\n\(sel)" }
            userContent.append(["type": "text", "text": text + "\n\nRequest: \(query)"])
        case nil:
            userContent.append(["type": "text", "text": query])
        }

        let system = """
        You are an assistant built into the notch of a Mac. Reply in English, short and precise.
        Reply ONLY with valid JSON in this exact format:
        {"title":"...","items":[{"label":"...","detail":"...","url":"..."}],"note":"..."}
        Maximum 3 items. "url" is optional. "note" is optional.
        """

        let tools: [[String: Any]] = [
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": tools,
            "system": system,
            "messages": [["role": "user", "content": userContent]],
        ]

        do {
            let result = try await callAPI(body: body, key: key, beta: "web-search-2025-03-05")
            await handleResult(result, state: state)
        } catch {
            await showError(APIError.describe(error), state: state)
        }
    }

    // MARK: - API call

    private func callAPI(body: [String: Any], key: String, beta: String? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw APIError(status: status, body: data, model: model) }
        return data
    }

    /// One streamed request (server-sent events). `onText` gets the message's text so far.
    /// Returns the content blocks as the non-streaming API would, to keep them in the history.
    private func streamMessage(body: [String: Any], key: String, beta: String?, kind: String,
                               onText: (String) -> Void) async throws -> (content: [[String: Any]], stopReason: String?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw APIError(status: status, body: data, model: model)
        }

        var blocks: [Int: [String: Any]] = [:]
        var toolInput: [Int: String] = [:]
        var stopReason: String?
        var usage: [String: Any] = [:]
        var responseModel = model

        for try await line in bytes.lines {
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            let index = event["index"] as? Int ?? 0

            switch type {
            case "message_start":
                let message = event["message"] as? [String: Any]
                usage = message?["usage"] as? [String: Any] ?? [:]
                responseModel = message?["model"] as? String ?? model
            case "content_block_start":
                var block = event["content_block"] as? [String: Any] ?? [:]
                if block["type"] as? String == "text" { block["text"] = block["text"] as? String ?? "" }
                blocks[index] = block
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { break }
                switch delta["type"] as? String {
                case "text_delta":
                    let piece = delta["text"] as? String ?? ""
                    blocks[index]?["text"] = (blocks[index]?["text"] as? String ?? "") + piece
                    onText(Self.text(of: Self.ordered(blocks)))
                case "input_json_delta":
                    toolInput[index, default: ""] += delta["partial_json"] as? String ?? ""
                case "citations_delta":
                    if let citation = delta["citation"] {
                        var list = blocks[index]?["citations"] as? [Any] ?? []
                        list.append(citation)
                        blocks[index]?["citations"] = list
                    }
                default: break
                }
            case "content_block_stop":
                if let json = toolInput[index] {
                    let input = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    blocks[index]?["input"] = input ?? [String: Any]()
                }
            case "message_delta":
                stopReason = (event["delta"] as? [String: Any])?["stop_reason"] as? String ?? stopReason
                if let more = event["usage"] as? [String: Any] { usage.merge(more) { $1 } }
            case "error":
                let err = event["error"] as? [String: Any]
                throw APIError(message: APIError.friendly(type: err?["type"] as? String,
                                                          message: err?["message"] as? String,
                                                          status: 0, model: model))
            default:
                break
            }
        }
        logUsage(["usage": usage, "model": responseModel], kind: kind)
        return (Self.ordered(blocks), stopReason)
    }

    // MARK: History limit and prompt caching (#9)

    /// Turns sent to the API: the first exchange (it carries the attachment) and the latest ones.
    /// Older turns in between are dropped so long chats don't grow without limit.
    static let maxRecentMessages = 21  // odd: the tail starts with a user turn

    static func trimmed(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard messages.count > maxRecentMessages + 2 else { return messages }
        let head = Array(messages.prefix(2))
        let tail = Array(messages.suffix(maxRecentMessages))
        return head + tail
    }

    /// Marks the last block of the last message as a cache breakpoint (copies; history stays clean).
    static func withCacheBreakpoint(_ messages: [[String: Any]]) -> [[String: Any]] {
        guard var last = messages.last else { return messages }
        var blocks: [[String: Any]]
        if let list = last["content"] as? [[String: Any]] {
            blocks = list
        } else if let text = last["content"] as? String {
            blocks = [["type": "text", "text": text]]
        } else {
            return messages
        }
        // Thinking/tool-use blocks can't carry cache_control: mark the last text or document block.
        guard let i = blocks.lastIndex(where: { ["text", "document", "image"].contains($0["type"] as? String ?? "") })
        else { return messages }
        blocks[i]["cache_control"] = ["type": "ephemeral"]
        last["content"] = blocks
        return Array(messages.dropLast()) + [last]
    }

    private static func ordered(_ blocks: [Int: [String: Any]]) -> [[String: Any]] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }

    /// The answer's text. Web search splits it into many text blocks (one per cited passage).
    static func text(of content: [[String: Any]]) -> String {
        content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    // MARK: - Chat result handler

    // MARK: - Structured result handler

    private func handleResult(_ data: Data, state: AppState) async {
        // Extract text from Anthropic response (may contain tool_use / web_search_tool_result blocks)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              case let text = Self.text(of: content), !text.isEmpty else {
            await showError("Unexpected API response.", state: state)
            return
        }
        logUsage(json, kind: "search")

        // Strip markdown code fences if present, then extract JSON object
        let cleanText: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            cleanText = String(text[start...end])
        } else {
            cleanText = text
        }

        // Try to parse as our JSON format
        if let resultData = cleanText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            let title  = parsed["title"] as? String ?? "Result"
            let note   = parsed["note"] as? String
            var items: [ResultItem] = []
            if let rawItems = parsed["items"] as? [[String: Any]] {
                for item in rawItems.prefix(3) {
                    items.append(ResultItem(
                        label:  item["label"]  as? String ?? "",
                        detail: item["detail"] as? String ?? "",
                        url:    item["url"]    as? String
                    ))
                }
            }
            state.searchResult = SearchResult(title: title, items: items, note: note)
        } else {
            // Fallback: show raw text in 3-line chunks
            let lines = cleanText.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(3)
            state.searchResult = SearchResult(
                title: "Claude's response",
                items: lines.map { ResultItem(label: $0, detail: "", url: nil) },
                note: nil
            )
        }

        state.stateOverride = nil
        state.view = .result
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
    }

    private func logUsage(_ json: [String: Any], kind: String) {
        guard let u = json["usage"] as? [String: Any] else { return }
        let input  = u["input_tokens"] as? Int ?? 0
        let output = u["output_tokens"] as? Int ?? 0
        let cacheW = u["cache_creation_input_tokens"] as? Int ?? 0
        let cacheR = u["cache_read_input_tokens"] as? Int ?? 0
        let turn   = conversationMessages.count / 2
        let model  = json["model"] as? String ?? self.model
        claudeLog.info("usage kind=\(kind, privacy: .public) model=\(model, privacy: .public) turn=\(turn) input=\(input) cache_write=\(cacheW) cache_read=\(cacheR) output=\(output)")
    }

    private func showError(_ message: String, state: AppState) async {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }

    // MARK: - File content block builder

    private func readFileAsBlock(url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let base64 = data.base64EncodedString()

        if ext == "pdf" {
            return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": base64]]
        } else if ["jpg", "jpeg"].contains(ext) {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]
        } else if ext == "png" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]]
        } else if ext == "gif" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/gif", "data": base64]]
        } else if ext == "webp" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/webp", "data": base64]]
        } else {
            // Text/code — inline as text if <= 200 KB
            guard data.count <= 200_000,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return ["type": "text", "text": "File contents:\n\(text)"]
        }
    }
}


// MARK: - API errors in plain words

/// Turns Anthropic API failures into something the user can act on.
struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(message: String) { self.message = message }

    init(status: Int, body: Data, model: String) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let err = json?["error"] as? [String: Any]
        message = Self.friendly(type: err?["type"] as? String, message: err?["message"] as? String,
                                status: status, model: model)
    }

    static func friendly(type: String?, message: String?, status: Int, model: String) -> String {
        let raw = message ?? ""
        let lower = raw.lowercased()
        switch (type, status) {
        case ("authentication_error", _), (_, 401):
            return "Your Anthropic API key was rejected. Check it in Settings → Claude, or switch the chat to your Claude Code subscription."
        case ("not_found_error", _) where lower.contains("model"), (_, 404):
            return "Your API key can't use the model \u{201C}\(model)\u{201D}. Pick another one in Settings → Model, or switch the chat to your Claude Code subscription."
        case ("permission_error", _), (_, 403):
            return "Your API key doesn't have permission for this (\(raw.isEmpty ? "forbidden" : raw)). Check the key's workspace in the Anthropic Console."
        case (_, 400) where lower.contains("credit balance"):
            return "Your Anthropic API credit balance is too low. Add credits in the Anthropic Console, or switch the chat to your Claude Code subscription."
        case ("rate_limit_error", _), (_, 429):
            return "The API is rate limiting this key. Wait a moment and try again."
        case ("overloaded_error", _), (_, 529):
            return "Claude is overloaded right now. Try again in a minute."
        case (_, 500...599), ("api_error", _):
            return "Anthropic's API had a problem (\(status)). Try again in a minute."
        default:
            return raw.isEmpty ? "The API answered with an error (\(status))." : raw
        }
    }

    /// Any error from a request: API errors as above, network errors in plain words.
    static func describe(_ error: Error) -> String {
        if let api = error as? APIError { return api.message }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "No internet connection. Check your network and try again."
            case .timedOut:
                return "Claude took too long to answer. Try again, or ask for something shorter."
            default: break
            }
        }
        return "Network error: \(error.localizedDescription)"
    }
}
