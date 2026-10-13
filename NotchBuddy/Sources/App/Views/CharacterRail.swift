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
    static let width: CGFloat = 62

    private var ids: [String?] { [nil] + state.assignedTaskIDs.map { Optional($0) } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(ids, id: \.self) { id in item(id) }
                }
                .padding(.vertical, 4)
            }
            // The island's quick controls, under the characters (the gear at the bottom, as in
            // the design).
            HStack(spacing: 4) {
                InboxButton()
                DoNotDisturbButton()
                Button { state.soundEnabled.toggle() } label: {
                    Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help(state.soundEnabled ? L("Mute") : L("Sound on"))
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .settings }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help(L("Settings"))
            }
            .scaleEffect(0.9)
            .padding(.vertical, 6)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.045)))
    }

    private func item(_ taskID: String?) -> some View {
        let critter = state.critter(for: taskID)
        let tint = state.critterTint(for: taskID)
        let palette = tint.map { critter.palette(tinted: $0) } ?? critter.palette
        let task = taskID.flatMap { id in state.tasks.first { $0.id == id } }
        // The same character twice: the label says which integration each one handles.
        let twice = ids.filter { state.critter(for: $0) == critter }.count > 1
        let label = twice ? (task?.name ?? "Claude") : critter.displayName
        return RailItem(state: state, taskID: taskID, selected: state.soloTaskID == taskID,
                        color: Color(cgColor: palette.top), label: label,
                        help: "\(critter.displayName) · \(task?.name ?? "Claude Code")") {
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
    let color: Color
    let label: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                // Room above and below the body for sprouts, steam, tentacles and hands.
                RailCharacterView(state: state, taskID: taskID)
                    .frame(width: 40, height: 40)
                Text(verbatim: label)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundColor(selected ? color : Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 52)
            }
            .padding(.bottom, 4)
            .frame(width: 54)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(selected ? Color.white.opacity(0.10) : hovered ? Color.white.opacity(0.05) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(selected ? color.opacity(0.9) : .clear, lineWidth: 1.5)
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
            Circle().fill(Color(hex: "#F5A524")).frame(width: 8, height: 8).offset(x: -4, y: 4)
        }
    }
}

/// One character, small but whole (face, smile, blush, its extras), in its own colours and with
/// its task's state.
private struct RailCharacterView: View {
    @ObservedObject var state: AppState
    let taskID: String?
    @StateObject private var engine = BotEngine()

    var body: some View {
        TimelineView(AlignedAnimationSchedule(interval: FrameRate.mini, paused: state.mode != .expanded)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt = min(0.05, now - engine.lastTime)
                engine.critter = state.critter(for: taskID)
                engine.userTint = state.critterTint(for: taskID)
                engine.bodyColor = nil
                let shown = taskID.map { id in state.tasks.first { $0.id == id }?.state ?? .idle } ?? state.mainBuddyState
                if engine.state != shown { engine.setState(shown) }
                engine.update(dt: dt)
                engine.drawHandsBehind(context: context, size: size)
                engine.draw(context: context, size: size)
                engine.drawHandsAndExtras(context: context, size: size)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The header beside the rail

/// Design C's header: the character's name and what it handles, then its tabs — Home · Chat ·
/// Code for the main character, its base and its own chat for an integration's character.
struct RailHeader: View {
    @ObservedObject var state: AppState

    private var task: AgentTask? { state.soloTaskID.flatMap { id in state.tasks.first { $0.id == id } } }

    private var critter: Critter { state.critter(for: task?.id) }
    private var nameColor: Color {
        let tint = state.critterTint(for: task?.id)
        return Color(cgColor: (tint.map { critter.palette(tinted: $0) } ?? critter.palette).top)
    }
    private var subtitle: String {
        guard let task else { return "Claude Code" }
        return task.steps.first.map { "\(task.name) · \($0)" } ?? task.name
    }
    private var inChat: Bool { ModeSwitch.chatViews.contains(state.view) }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: critter.displayName)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(nameColor)
            Text(verbatim: subtitle)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                if let task {
                    let base = Self.base(for: task)
                    LabeledSegment(icon: base.icon, label: base.label, on: !inChat) {
                        CharacterRail.pick(task.id, state: state)
                    }
                    LabeledSegment(icon: "bubble.left", label: L("Ask"), on: inChat && state.chatOwner == task.id) {
                        CharacterChat.open(task.id, state: state)
                    }
                } else {
                    LabeledSegment(icon: "house", label: L("Home"),
                                   on: state.view == .overview || state.view == .empty) {
                        CharacterRail.pick(nil, state: state)
                    }
                    LabeledSegment(icon: "bubble.left", label: L("Chat"), on: inChat && !state.isCoding) {
                        ModeSwitch.showChat(state)
                    }
                    LabeledSegment(icon: "chevron.left.forwardslash.chevron.right", label: L("Code"),
                                   on: inChat && state.isCoding) {
                        ModeSwitch.showCode(state)
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.06)))
        }
        .padding(.trailing, 10)
    }

    /// What an integration's base tab is called: its mail, its tickets, its orders…
    static func base(for task: AgentTask) -> (icon: String, label: String) {
        switch task.id {
        case "integration_gmail", "integration_resend": return ("envelope", L("Mail"))
        case "integration_whaticket": return ("ticket", L("Tickets"))
        case "integration_aliexpress": return ("shippingbox", L("Orders"))
        case "integration_github": return ("arrow.triangle.pull", L("PRs"))
        case "integration_linear": return ("checklist", L("Issues"))
        case "integration_calcom": return ("calendar", L("Calendar"))
        default: return ("house", L("Home"))
        }
    }
}

private struct LabeledSegment: View {
    let icon: String
    let label: String
    let on: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(verbatim: label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(on ? Color(hex: "#F5F6F8") : hovered ? Color(hex: "#C5C8CD") : Color(hex: "#9A9EA6"))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color(hex: "#34363D") : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
