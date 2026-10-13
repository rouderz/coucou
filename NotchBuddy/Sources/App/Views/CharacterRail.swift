import AppKit
import SwiftUI

// The character rail (island design C): once an integration has its own character, the island's
// left side lists the characters — the main one (Claude Code, Chat and Code) on top, then one
// per integration. Picking one shows its base; an integration's character also has its own chat,
// about what it handles, kept apart from the main character's conversations.

extension Notification.Name {
    /// A character was picked in the rail; object: its free-placement key ("main" or a task id).
    static let characterRailPicked = Notification.Name("notchBuddy.characterRailPicked")
}

struct CharacterRail: View {
    @ObservedObject var state: AppState

    /// Where the rail shows: the overview and the chat.
    static let views: Set<IslandView> = [.overview, .empty, .prompt, .searching, .result]
    static let width: CGFloat = 54

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                item(nil)
                ForEach(state.assignedTaskIDs, id: \.self) { id in item(id) }
            }
            .padding(.vertical, 4)
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.045)))
    }

    private func item(_ taskID: String?) -> some View {
        let selected = state.soloTaskID == taskID
        let critter = state.critter(for: taskID)
        let tint = taskID.flatMap { state.critterTint(for: $0) }
        let palette = tint.map { critter.palette(tinted: $0) } ?? critter.palette
        let task = taskID.flatMap { id in state.tasks.first { $0.id == id } }
        return RailItem(state: state, taskID: taskID, selected: selected, ring: Color(cgColor: palette.top),
                        help: task.map { "\(critter.displayName) · \($0.name)" } ?? "\(critter.displayName) · Claude Code") {
            CharacterRail.pick(taskID, state: state)
        }
    }

    /// Shows that character's base: the main one's overview, or just its integration.
    static func pick(_ taskID: String?, state: AppState) {
        if state.chatOwner != nil && state.chatOwner != taskID { CharacterChat.leave(state) }
        state.selectCharacter(taskID)
        NotificationCenter.default.post(name: .characterRailPicked, object: taskID ?? FreeBuddyController.mainKey)
        NotificationCenter.default.post(name: .botBlink, object: nil)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            state.view = state.tasks.isEmpty ? .empty : .overview
        }
    }
}

private struct RailItem: View {
    @ObservedObject var state: AppState
    let taskID: String?
    let selected: Bool
    let ring: Color
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            RailCharacterView(state: state, taskID: taskID)
                .frame(width: 46, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(selected ? Color.white.opacity(0.10) : hovered ? Color.white.opacity(0.05) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(selected ? ring.opacity(0.85) : .clear, lineWidth: 1.5)
                )
                .overlay(alignment: .topTrailing) { badge }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Text(verbatim: help))
        .accessibilityLabel(Text(verbatim: help))
    }

    /// Something waiting on that character (an alert badge on its task).
    @ViewBuilder private var badge: some View {
        if let id = taskID, !selected, state.tasks.first(where: { $0.id == id })?.pillBadge != nil {
            Circle().fill(Color(hex: "#F5A524")).frame(width: 8, height: 8).offset(x: -3, y: 3)
        }
    }
}

/// One character, small, with its own colours and its task's state.
private struct RailCharacterView: View {
    @ObservedObject var state: AppState
    let taskID: String?
    @StateObject private var engine: BotEngine = {
        let e = BotEngine()
        e.isMini = true
        return e
    }()

    var body: some View {
        TimelineView(AlignedAnimationSchedule(interval: FrameRate.mini, paused: state.mode != .expanded)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt = min(0.05, now - engine.lastTime)
                engine.critter = state.critter(for: taskID)
                engine.userTint = taskID.flatMap { state.critterTint(for: $0) }
                engine.bodyColor = nil
                let shown = taskID.map { id in state.tasks.first { $0.id == id }?.state ?? .idle } ?? state.mainBuddyState
                if engine.state != shown { engine.setState(shown) }
                engine.update(dt: dt)
                engine.draw(context: context, size: size)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - An integration character's tabs

/// In place of Home · Chat / Code · +: the character's name, its integration, and two tabs —
/// its base (the integration's card) and its own chat about it.
struct CharacterTabs: View {
    @ObservedObject var state: AppState
    let task: AgentTask

    private var critter: Critter { state.critter(for: task.id) }
    private var nameColor: Color {
        let tint = state.critterTint(for: task.id)
        return Color(cgColor: (tint.map { critter.palette(tinted: $0) } ?? critter.palette).top)
    }
    private var inChat: Bool { state.chatOwner == task.id && ModeSwitch.chatViews.contains(state.view) }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: critter.displayName)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(nameColor)
            Text(verbatim: task.name)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
            HStack(spacing: 2) {
                segment(icon: "house.fill", on: !inChat, label: L("Home")) {
                    CharacterRail.pick(task.id, state: state)
                }
                segment(icon: "bubble.left.and.bubble.right", on: inChat, label: L("Ask \(critter.displayName)")) {
                    CharacterChat.open(task.id, state: state)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }

    private func segment(icon: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(on ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                .frame(width: 34, height: 22)
                .background(Capsule().fill(on ? Color(hex: "#2A2D33") : .clear))
                .overlay(Capsule().stroke(on ? Color.white.opacity(0.12) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: label))
        .accessibilityLabel(Text(verbatim: label))
    }
}

// MARK: - An integration character's own chat

/// Each integration's character keeps its own conversation, about what that integration shows.
/// Switching saves the one on screen and brings back the other's where you left it.
@MainActor
enum CharacterChat {
    /// The main character's mode when a character's chat took over, to come back to it.
    private static var returnMode: ChatMode = .chat

    static func open(_ taskID: String, state: AppState) {
        guard let task = state.tasks.first(where: { $0.id == taskID }) else { return }
        if state.chatOwner != taskID {
            if state.chatOwner != nil {
                stashOwner(state)
            } else {
                ChatStore.shared.saveCurrent(state)
                state.stashedChatIDs[state.chatMode] = state.currentChatID
                returnMode = state.chatMode
            }
            if let id = state.stashedCharacterChats[taskID],
               let chat = ChatStore.shared.chats.first(where: { $0.id == id }) {
                ChatStore.shared.open(chat, in: state)
            } else {
                ChatSession.startNew(state)
                attachContext(task, state: state)
            }
            state.chatOwner = taskID
        }
        state.soloTaskID = taskID
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .prompt }
    }

    /// Back to the main character: the character's chat is kept for later, the main one's
    /// conversation comes back.
    static func leave(_ state: AppState) {
        guard state.chatOwner != nil else { return }
        stashOwner(state)
        state.chatMode = returnMode
        if let id = state.stashedChatIDs[returnMode],
           let chat = ChatStore.shared.chats.first(where: { $0.id == id }) {
            ChatStore.shared.open(chat, in: state)
            state.chatMode = returnMode
        } else {
            ChatSession.startNew(state)
            if returnMode == .code, let folder = state.codeFolder { CodeMode.begin(folder, state: state) }
        }
    }

    private static func stashOwner(_ state: AppState) {
        guard let owner = state.chatOwner else { return }
        ChatStore.shared.saveCurrent(state)
        if let id = state.currentChatID { state.stashedCharacterChats[owner] = id }
        state.chatOwner = nil
    }

    /// What the integration shows right now, as the chat's context file.
    private static func attachContext(_ task: AgentTask, state: AppState) {
        let critter = state.critter(for: task.id)
        var lines = ["You are \(critter.displayName), the character in charge of \(task.name) in Coucou.",
                     "Answer questions about \(task.name) using what it shows right now:"]
        lines += task.steps.isEmpty ? ["(nothing to show yet)"] : task.steps.map { "- \($0)" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Coucou", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = task.name.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(safe).txt")
        guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        state.promptContext = .file(name: task.name, fileURL: url)
    }
}
