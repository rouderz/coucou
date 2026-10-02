import SwiftUI

// Mochi's chat: prompt, bubbles, history list, push-to-talk, search and results.

// MARK: - Prompt (chat)

struct PromptView: View {
    @ObservedObject var state: AppState
    @State private var text: String = ""
    @State private var showHistory = false
    @FocusState private var focused: Bool
    @ObservedObject private var skillsStore = SkillsStore.shared
    @State private var pickIndex = 0

    /// "/" at the start of the field lists the skills, in the chat's place.
    private var picking: Bool { text.hasPrefix("/") && !text.contains(" ") }
    private var matches: [SkillInfo] { SkillFiles.match(skillsStore.skills, typed: text) }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let ctx = state.promptContext {
                        ContextChip(context: ctx)
                        // Code context: let Mochi change files, each change approved in the island
                        if case .code = ctx, ClaudeService.provider(for: state.chatEngine).capabilities.contains(.editsFiles) {
                            Button { state.chatAllowEdits.toggle() } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: state.chatAllowEdits ? "pencil.circle.fill" : "pencil.slash")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(state.chatAllowEdits ? "Edits on" : "Read-only")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(state.chatAllowEdits ? Color(hex: "#22C55E") : Color(hex: "#8E939C"))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background((state.chatAllowEdits ? Color(hex: "#22C55E") : Color.white).opacity(0.1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(state.chatAllowEdits
                                  ? L("Mochi can change files in this project. You approve every change in the island.")
                                  : L("Mochi can only read this project. Click to let it propose edits."))
                        }
                    }
                    if let skill = state.chatSkill {
                        Button { state.chatSkill = nil } label: {
                            Text(verbatim: "✦ \(skill.name) ×")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#C4B5FD"))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color(hex: "#A78BFA").opacity(0.14))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L("Remove the skill"))
                    }
                    Spacer(minLength: 4)
                    if state.voiceSpeaking {
                        HeaderIconButton(symbol: "speaker.slash.fill", active: true, help: L("Stop reading aloud")) {
                            VoiceOutput.shared.stop()
                        }
                    }
                    HeaderIconButton(symbol: "clock.arrow.circlepath", active: showHistory,
                                     help: L("Chat history")) { showHistory.toggle() }
                    if !state.chatHistory.isEmpty || state.promptContext != nil {
                        HeaderIconButton(symbol: "square.and.pencil", active: false, help: L("New chat")) {
                            ChatSession.startNew(state)
                            showHistory = false
                            focused = true
                        }
                    }
                }
                .padding(.top, 2)

                if showHistory {
                    ChatHistoryList(state: state) { showHistory = false; focused = true }
                        .frame(maxHeight: .infinity)
                } else if picking {
                    SkillPickerList(matches: matches, selected: pickIndex, hasAny: !skillsStore.skills.isEmpty) { choose($0) }
                        .frame(maxHeight: .infinity)
                } else if !state.chatHistory.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(state.chatHistory) { msg in
                                    ChatBubble(message: msg).id(msg.id)
                                }
                                if state.stateOverride != nil {
                                    HStack { TypingDotsView(); Spacer(minLength: 32) }
                                        .id("typing")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onChange(of: state.chatHistory.count) { _, _ in
                            if let last = state.chatHistory.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: state.chatHistory.last?.content) { _, _ in
                            if let last = state.chatHistory.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onChange(of: state.stateOverride) { _, v in
                            if v != nil { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                        }
                        .onAppear {
                            if let last = state.chatHistory.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }

                if !showHistory {
                HStack(spacing: 8) {
                    if state.voicePhase != .idle {
                        VoiceListeningLabel(phase: state.voicePhase, transcript: state.voiceTranscript)
                    } else {
                        TextField(state.chatSkill != nil ? "What should it do?"
                                  : state.chatHistory.isEmpty ? "Ask me anything… (/ for skills)" : "Continue…", text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($focused)
                            .onSubmit {
                                if picking, matches.indices.contains(pickIndex) { choose(matches[pickIndex]) } else { sendMessage() }
                            }
                            .onChange(of: text) { old, new in
                                if new == "/", !old.hasPrefix("/") { skillsStore.refresh() }
                                pickIndex = 0
                            }
                            .onKeyPress(.downArrow) {
                                guard picking, !matches.isEmpty else { return .ignored }
                                pickIndex = (pickIndex + 1) % matches.count
                                return .handled
                            }
                            .onKeyPress(.upArrow) {
                                guard picking, !matches.isEmpty else { return .ignored }
                                pickIndex = (pickIndex + matches.count - 1) % matches.count
                                return .handled
                            }
                            .onKeyPress(.tab) {
                                guard picking, matches.indices.contains(pickIndex) else { return .ignored }
                                choose(matches[pickIndex])
                                return .handled
                            }
                    }

                    if state.voiceEnabled && text.isEmpty {
                        Button { VoiceSession.toggle(state) } label: {
                            Image(systemName: state.voicePhase == .listening ? "stop.fill" : "mic.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(state.voicePhase == .listening ? Color(hex: "#F4505E") : Color(hex: "#8E939C"))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(state.voicePhase == .listening ? L("Stop and send") : L("Talk to Mochi (or hold the push-to-talk shortcut)"))
                    }

                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(text.isEmpty)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .simultaneousGesture(TapGesture().onEnded { focused = true })
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .padding(.bottom, 10)
        .onAppear { focused = true }
    }

    private func choose(_ skill: SkillInfo) {
        state.chatSkill = SkillRef(name: skill.name, path: skill.path)
        text = ""
        pickIndex = 0
        focused = true
    }

    private func sendMessage() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        text = ""
        ChatSession.send(query, state: state, spoken: false)
        focused = true
    }
}


/// The skills matching what follows "/" in the chat field.
struct SkillPickerList: View {
    let matches: [SkillInfo]
    let selected: Int
    let hasAny: Bool
    let choose: (SkillInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            if matches.isEmpty {
                Text(hasAny ? "No skill matches." : "No skills installed. Add some in Settings → Skills.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .padding(.horizontal, 9)
            }
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, skill in
                Button { choose(skill) } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: "/\(skill.name)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(hex: "#C4B5FD"))
                        Text(verbatim: skill.description)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.white.opacity(0.5))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.white.opacity(index == selected ? 0.08 : 0))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 32)
                Text(message.content)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#F1F2F4"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text(message.content)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#B0B5BE"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
            }
        }
    }
}

struct TypingDotsView: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(hex: "#6B7079"))
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase ? 1.2 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.14),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, 2).padding(.vertical, 4)
        .onAppear { phase = true }
    }
}

// MARK: - Searching

struct SearchingView: View {
    @ObservedObject var state: AppState

    var label: String {
        switch state.promptContext {
        case .window(_, let title, _): return L("Claude is reading \(title)…")
        case .file(let name, _): return L("Claude is reading \(name)…")
        case .code(let code): return L("Claude is reading \(code.fileName)…")
        case nil: return L("Claude is searching…")
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 8) {
                if let ctx = state.promptContext {
                    ContextChip(context: ctx)
                }
                ShimmeringText(label)
                    .font(.system(size: 13.5))
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
        }
    }
}

// MARK: - Result

struct ResultView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .green)

            if let result = state.searchResult {
                VStack(alignment: .leading, spacing: 7) {
                    Text(result.title)
                        .font(.system(size: 15, weight: .semibold))

                    VStack(spacing: 4) {
                        ForEach(result.items.prefix(3), id: \.label) { item in
                            HStack {
                                Text(item.label).font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Text(item.detail).font(.system(size: 12.5)).foregroundColor(Color(hex: "#9398A1"))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    if let note = result.note {
                        Text(note).font(.system(size: 11)).foregroundColor(Color(hex: "#6E737C"))
                    }

                    HStack(spacing: 8) {
                        PrimaryButton("Open") {
                            if let urlStr = result.items.first?.url, let url = URL(string: urlStr) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        SecondaryButton("Copy") {
                            let text = result.items.map { "\($0.label): \($0.detail)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        SecondaryButton("Close") { state.view = state.tasks.isEmpty ? .empty : .overview }
                    }
                }
                .padding(.leading, 84)
                .padding(.trailing, 16)
            }
        }
    }
}

// MARK: - Chat history

struct HeaderIconButton: View {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(active ? Color(hex: "#F5F6F8") : Color(hex: hover ? "#C5C8CD" : "#8E939C"))
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(active ? 0.14 : hover ? 0.08 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(LocalizedStringKey(help))
    }
}

/// Saved conversations, newest first. Click one to continue it.
struct ChatHistoryList: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = ChatStore.shared
    let onOpen: () -> Void

    var body: some View {
        if store.chats.isEmpty {
            VStack(spacing: 4) {
                Spacer()
                Text("No saved chats yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                Text("Conversations with Mochi are kept here so you can pick them up later.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.chats) { chat in
                            ChatHistoryRow(chat: chat, current: chat.id == state.currentChatID,
                                           open: { store.open(chat, in: state); onOpen() },
                                           delete: { store.delete(chat, in: state) })
                        }
                    }
                }
                HStack {
                    Text("\(store.chats.count) saved · last \(ChatStore.maxChats) kept")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#6B7079"))
                    Spacer()
                    Button("Clear all") { store.deleteAll(in: state) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
            }
        }
    }
}

struct ChatHistoryRow: View {
    let chat: SavedChat
    let current: Bool
    let open: () -> Void
    let delete: () -> Void
    @State private var hover = false

    private var subtitle: String {
        var parts = [chat.updatedAt.formatted(.relative(presentation: .named))]
        if let code = chat.code { parts.append(code.projectName) }
        else if let label = chat.contextLabel { parts.append(label) }
        parts.append("\(chat.messages.count) msgs")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: chat.code != nil ? "chevron.left.forwardslash.chevron.right" : "bubble.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(hex: current ? "#4C8DFF" : "#6B7079"))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "#E6E8EB"))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help("Delete this chat")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(current ? 0.1 : hover ? 0.06 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }
}


// MARK: - Push-to-talk

/// Replaces the text field while Mochi is listening: a pulsing dot and the live transcript.
struct VoiceListeningLabel: View {
    let phase: VoicePhase
    let transcript: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(hex: "#F4505E"))
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.25 : 0.8)
                .opacity(phase == .listening ? 1 : 0.4)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: pulse)
                .onAppear { pulse = true }
            Text(transcript.isEmpty ? (phase == .listening ? L("Listening…") : L("Transcribing…")) : transcript)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: transcript.isEmpty ? "#8E939C" : "#F1F2F4"))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
    }
}
