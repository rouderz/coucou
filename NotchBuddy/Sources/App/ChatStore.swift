import Foundation
import os

/// One saved conversation with Mochi.
struct SavedChat: Codable, Identifiable, Equatable {
    struct Message: Codable, Equatable {
        let user: Bool
        let text: String
    }
    let id: UUID
    var title: String
    var updatedAt: Date
    var messages: [Message]
    /// Claude Code engine: the session to `--resume` and the folder it ran in.
    var sessionID: String?
    var workDir: String?
    /// Set when the chat was about a project (assistant mode); restored as the context chip.
    var code: CodeContext?
    /// Short description of other attachments (a window, a file) for the list.
    var contextLabel: String?
}

/// Mochi's chat history: kept in Application Support/NotchBuddy/chats.json, newest first.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()
    static let maxChats = 50

    @Published private(set) var chats: [SavedChat] = []

    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy", isDirectory: true)
    }
    private static var fileURL: URL { dir.appendingPathComponent("chats.json") }
    /// Folders the Claude Code engine runs plain chats in (kept so `--resume` finds them).
    static var workDirsRoot: URL { dir.appendingPathComponent("chats", isDirectory: true) }

    private init() { load() }

    // MARK: - Save the current conversation

    /// Saves (or updates) the conversation on screen. Called after every answer.
    func saveCurrent(_ state: AppState) {
        let messages = state.chatHistory.map { SavedChat.Message(user: $0.role == .user, text: $0.content) }
        guard messages.contains(where: { $0.user }) else { return }
        let engine = ClaudeCodeChat.shared.snapshot
        let id = state.currentChatID ?? UUID()
        state.currentChatID = id

        var chat = chats.first { $0.id == id } ?? SavedChat(
            id: id, title: Self.title(from: messages), updatedAt: .now, messages: [])
        chat.messages = messages
        chat.updatedAt = .now
        if let sid = engine.sessionID { chat.sessionID = sid }
        if let dir = engine.workDir { chat.workDir = dir }
        switch state.promptContext {
        case .code(let c)?: chat.code = c
        case .window(let app, let title, _)?: chat.contextLabel = "\(app) · \(title)"
        case .file(let name, _)?: chat.contextLabel = name
        case nil: break
        }

        chats.removeAll { $0.id == id }
        chats.insert(chat, at: 0)
        prune()
        persist()
    }

    // MARK: - Open / delete

    /// Puts a saved conversation back on screen; the next message continues it.
    func open(_ chat: SavedChat, in state: AppState) {
        ChatSession.startNew(state)
        state.currentChatID = chat.id
        state.chatHistory = chat.messages.map { ChatMessage(role: $0.user ? .user : .assistant, content: $0.text) }
        state.promptContext = chat.code.map { PromptContext.code($0) }
        AnthropicAPIChat.shared.restore(chat.messages)
        OpenAICompatibleChat.shared.restore(chat.messages)
        ClaudeCodeChat.shared.restore(sessionID: chat.sessionID,
                                      workDir: chat.workDir,
                                      projectDir: chat.code?.project)
    }

    func delete(_ chat: SavedChat, in state: AppState) {
        chats.removeAll { $0.id == chat.id }
        removeWorkDir(of: chat)
        if state.currentChatID == chat.id { ChatSession.startNew(state) }
        persist()
    }

    func deleteAll(in state: AppState) {
        chats.forEach(removeWorkDir)
        chats = []
        ChatSession.startNew(state)
        persist()
    }

    // MARK: - Helpers

    private static func title(from messages: [SavedChat.Message]) -> String {
        let first = messages.first { $0.user }?.text ?? "Chat"
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }

    private func prune() {
        while chats.count > Self.maxChats {
            let old = chats.removeLast()
            removeWorkDir(of: old)
        }
    }

    /// Only folders Coucou created for plain chats — never the user's project.
    private func removeWorkDir(of chat: SavedChat) {
        guard let dir = chat.workDir, dir.hasPrefix(Self.workDirsRoot.path + "/") else { return }
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { chats = try decoder.decode([SavedChat].self, from: data) }
        catch { log.error("chat history unreadable: \(error.localizedDescription, privacy: .public)") }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try encoder.encode(chats).write(to: Self.fileURL, options: [.atomic])
        } catch {
            log.error("chat history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Starting a fresh conversation, in one place (new chat button, ⌃⌥M, Ask Mochi…).
@MainActor
enum ChatSession {
    static func startNew(_ state: AppState) {
        state.chatHistory = []
        state.currentChatID = nil
        state.promptContext = nil
        state.chatAllowEdits = false
        AnthropicAPIChat.shared.reset()
        ClaudeCodeChat.shared.reset()
        OpenAICompatibleChat.shared.reset()
    }
}
