import AppKit
import SwiftUI

// Chat / Code (#149, #152).
//
// Chat: the conversation with the engine picked in Settings, about anything.
// Code: Claude Code at work in a folder you pick — it reads and searches the project, and with
// edits on it changes files and runs commands, each one approved in the island (the same
// PermissionRequest path as the chat's edits). Each mode keeps its own conversation: switching
// saves the one on screen and brings back the other's where you left it.

enum ChatMode: String, Sendable {
    case chat, code
}

extension CodeContext {
    /// A whole folder (Code mode) rather than a file open in an editor.
    var isFolder: Bool { file == project }

    static func folder(_ path: String) -> CodeContext {
        CodeContext(appName: "Folder", file: path, project: path, selection: nil)
    }
}

@MainActor
enum CodeMode {
    static let maxRecent = 6

    /// Shows Chat or Code, each with its own conversation.
    static func show(_ mode: ChatMode, state: AppState) {
        if mode != state.chatMode {
            ChatStore.shared.saveCurrent(state)
            state.stashedChatIDs[state.chatMode] = state.currentChatID
            state.chatMode = mode
            if let id = state.stashedChatIDs[mode], let chat = ChatStore.shared.chats.first(where: { $0.id == id }) {
                ChatStore.shared.open(chat, in: state)
                state.chatMode = mode
            } else {
                ChatSession.startNew(state)
                if mode == .code, let folder = state.codeFolder { begin(folder, state: state) }
            }
        }
        if mode == .chat {
            #if !APPSTORE
            if state.promptContext == nil {
                state.promptContext = WindowContextCapture.captureActive(from: state.lastExternalApp)
            }
            #endif
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .prompt }
    }

    /// Code mode starts working in this folder: Claude Code runs there, edits on.
    static func begin(_ folder: String, state: AppState) {
        state.codeFolder = folder
        state.recentCodeFolders = ([folder] + state.recentCodeFolders.filter { $0 != folder }).prefix(maxRecent).map { $0 }
        state.promptContext = .code(.folder(folder))
        state.chatAllowEdits = true
    }

    /// Another folder: the conversation about the previous one is kept in the history, and a new
    /// one starts in the new folder.
    static func switchFolder(_ folder: String, state: AppState) {
        if case .code(let c)? = state.promptContext, c.isFolder, c.project == folder { return }
        ChatStore.shared.saveCurrent(state)
        ChatSession.startNew(state)
        begin(folder, state: state)
    }

    /// Asks for a folder (the system's folder picker).
    static func pickFolder(state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Code here")
        panel.message = L("The folder Claude Code works in")
        if let current = state.codeFolder { panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switchFolder(url.path, state: state)
    }

    /// Folders worth offering: the recent ones, then the folders of live Claude Code sessions.
    static func suggestions(state: AppState) -> [String] {
        var seen = Set<String>()
        let all = state.recentCodeFolders + state.claudeSessions.map(\.cwd)
        return all.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
            .prefix(8).map { $0 }
    }
}

// MARK: - The folder chip in the Code chat

/// "📁 coucou ▾": the folder Claude Code works in; the menu switches to a recent one or opens
/// the folder picker.
struct CodeFolderChip: View {
    @ObservedObject var state: AppState

    private var name: String {
        state.codeFolder.map { ($0 as NSString).lastPathComponent } ?? L("Choose a folder")
    }

    var body: some View {
        Menu {
            ForEach(CodeMode.suggestions(state: state), id: \.self) { folder in
                Button((folder as NSString).abbreviatingWithTildeInPath) { CodeMode.switchFolder(folder, state: state) }
            }
            Divider()
            Button(L("Other folder…")) { CodeMode.pickFolder(state: state) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").font(.system(size: 10))
                Text(verbatim: name).font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(Color(hex: "#F1F2F4"))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.codeFolder ?? L("The folder Claude Code works in"))
    }
}

/// Code mode without a folder yet: one big button.
struct CodeFolderPrompt: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("Pick the folder to code in. Claude Code reads it, and changes files or runs commands only when you approve each one in the island.")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#9398A1"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(L("Choose a folder")) { CodeMode.pickFolder(state: state) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}
