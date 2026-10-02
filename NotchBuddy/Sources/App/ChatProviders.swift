import Foundation
import os

// MARK: - Port (#16)

/// What every chat backend does for Mochi: one user turn in, the answer streamed back.
/// Claude Code (subscription) and the Anthropic API live in ClaudeCodeChat / ClaudeService;
/// other providers implement this.
@MainActor
protocol ChatProvider: AnyObject {
    func send(query: String, context: PromptContext?, systemPrompt: String,
              onText: @escaping @MainActor (String) -> Void) async throws -> String
    func reset()
    func restore(_ messages: [SavedChat.Message])
}

// MARK: - Providers (#42, #43)

/// OpenAI-compatible chat endpoints: OpenAI, Gemini, OpenRouter, Ollama, LM Studio or any other.
struct ProviderPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let needsKey: Bool
    let defaultModel: String
    let keyHint: String

    static let all: [ProviderPreset] = [
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", needsKey: true,
              defaultModel: "gpt-5", keyHint: "sk-…"),
        .init(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
              needsKey: true, defaultModel: "gemini-2.5-flash", keyHint: "AIza…"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", needsKey: true,
              defaultModel: "openrouter/auto", keyHint: "sk-or-…"),
        .init(id: "ollama", name: "Ollama (on this Mac)", baseURL: "http://localhost:11434/v1", needsKey: false,
              defaultModel: "llama3.2", keyHint: ""),
        .init(id: "lmstudio", name: "LM Studio (on this Mac)", baseURL: "http://localhost:1234/v1", needsKey: false,
              defaultModel: "", keyHint: ""),
        .init(id: "custom", name: "Custom (OpenAI-compatible)", baseURL: "", needsKey: false,
              defaultModel: "", keyHint: "optional"),
    ]

    static func find(_ id: String) -> ProviderPreset { all.first { $0.id == id } ?? all[0] }
    var keychainKey: String { "provider-key-\(id)" }
}

/// Settings for the "Other provider" engine, read where needed.
@MainActor
enum ProviderSettings {
    static var preset: ProviderPreset { ProviderPreset.find(AppState.shared.providerID) }

    static var baseURL: String {
        let custom = AppState.shared.providerBaseURL.trimmingCharacters(in: .whitespaces)
        return (custom.isEmpty ? preset.baseURL : custom).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static var model: String {
        let m = AppState.shared.providerModel.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? preset.defaultModel : m
    }

    static var key: String? {
        Secrets.store.get(preset.keychainKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Models the server offers (GET /models), for the picker.
    static func listModels() async throws -> [String] {
        guard let url = URL(string: baseURL + "/models") else { throw APIError(message: L("Invalid server address")) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw OpenAICompatibleChat.error(code: code, data: data, model: model) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }.sorted()
    }
}

/// /chat/completions with streaming. Files and code context go inline as text.
@MainActor
final class OpenAICompatibleChat: ChatProvider {
    static let shared = OpenAICompatibleChat()
    private var messages: [[String: Any]] = []
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")
    private let maxHistory = 30

    func reset() { messages = [] }

    func restore(_ saved: [SavedChat.Message]) {
        messages = saved.map { ["role": $0.user ? "user" : "assistant", "content": $0.text] }
        while messages.last?["role"] as? String == "user" { messages.removeLast() }
    }

    func send(query: String, context: PromptContext?, systemPrompt: String,
              onText: @escaping @MainActor (String) -> Void) async throws -> String {
        let preset = ProviderSettings.preset
        let key = ProviderSettings.key
        if preset.needsKey && key == nil {
            throw APIError(message: L("Add your \(preset.name) API key in Settings → Chat."))
        }
        guard let url = URL(string: ProviderSettings.baseURL + "/chat/completions") else {
            throw APIError(message: L("Invalid server address"))
        }

        var content = ""
        if messages.isEmpty, let context { content = Self.contextText(context) }
        content += query
        messages.append(["role": "user", "content": content])

        let history = Array(messages.suffix(maxHistory))
        let body: [String: Any] = [
            "model": ProviderSettings.model,
            "stream": true,
            "messages": [["role": "system", "content": systemPrompt]] + history,
        ]
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if preset.id == "openrouter" {
            req.setValue("https://github.com/rouderz/coucou", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("Coucou", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                var data = Data()
                for try await b in bytes { data.append(b) }
                throw Self.error(code: code, data: data, model: ProviderSettings.model)
            }
            var answer = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let err = json["error"] as? [String: Any] {
                    throw APIError(message: err["message"] as? String ?? L("The provider answered with an error."))
                }
                let delta = ((json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
                if let delta, !delta.isEmpty {
                    answer += delta
                    onText(answer)
                }
            }
            let final = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty else { throw APIError(message: L("Claude didn't write an answer. Try asking again.")) }
            messages.append(["role": "assistant", "content": final])
            log.info("chat via \(preset.id, privacy: .public) model=\(ProviderSettings.model, privacy: .public)")
            return final
        } catch {
            if messages.last?["role"] as? String == "user" { messages.removeLast() }
            if let url = error as? URLError, [.cannotConnectToHost, .cannotFindHost].contains(url.code), !preset.needsKey {
                throw APIError(message: L("\(preset.name) isn't answering at \(ProviderSettings.baseURL). Is it running?"))
            }
            throw error
        }
    }

    /// Attached window / file / code as plain text (these providers get no files).
    private static func contextText(_ context: PromptContext) -> String {
        switch context {
        case .window(let app, let title, let url):
            return "Context — App: \(app), Window: \(title)" + (url.map { ", URL: \($0)" } ?? "") + "\n\n"
        case .file(let name, let url):
            return "File: \(name)\n" + (url.flatMap(fileText).map { "```\n\($0)\n```\n\n" } ?? "\n")
        case .code(let code):
            let text = fileText(URL(fileURLWithPath: code.file)).map { "```\n\($0)\n```\n" } ?? ""
            return text + code.inlinePreamble
        }
    }

    private static func fileText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 200_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func error(code: Int, data: Data, model: String) -> APIError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? (json?["error"] as? String) ?? ""
        switch code {
        case 401, 403: return APIError(message: L("The provider rejected the API key. Check it in Settings → Chat."))
        case 404: return APIError(message: L("The provider doesn't know the model \u{201C}\(model)\u{201D}. Pick another in Settings → Chat (Load models)."))
        case 429: return APIError(message: L("The provider is rate limiting this key. Wait a moment and try again."))
        default: return APIError(message: message.isEmpty ? L("The provider answered with an error (\(code)).") : message)
        }
    }
}
