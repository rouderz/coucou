import AppKit
import SwiftUI

// MARK: - Model (#22)

/// One thing that happened in a Claude Code session, with when and how long.
struct TimelineEntry: Identifiable, Sendable {
    enum Kind: Sendable { case prompt, read, search, edit, write, command, web, agent, approval, done, failed, other }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String?
    let start: Date
    var end: Date?
    var failed = false
    let toolUseID: String?
    let tool: String?

    var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
    var running: Bool { end == nil && !([.prompt, .approval, .done, .failed] as [Kind]).contains(kind) }
}

/// Every session's timeline, fed by the hook (all sessions, on the card or not).
@MainActor
final class TimelineStore: ObservableObject {
    static let shared = TimelineStore()
    @Published private(set) var entries: [String: [TimelineEntry]] = [:]

    private let maxEntries = 400
    private let maxSessions = 20

    func record(event: String, sessionId: String, payload: [String: Any]) {
        guard sessionId != "unknown" else { return }
        let now = Date.now
        switch event {
        case "SessionStart":
            append(sessionId, TimelineEntry(kind: .other, title: L("Session started"), detail: payload["cwd"] as? String,
                                            start: now, end: now, toolUseID: nil, tool: nil))
        case "UserPromptSubmit":
            guard let prompt = payload["prompt"] as? String, !prompt.isEmpty else { return }
            append(sessionId, TimelineEntry(kind: .prompt, title: L("You asked"), detail: String(prompt.prefix(240)),
                                            start: now, end: now, toolUseID: nil, tool: nil))
        case "PreToolUse":
            let tool = payload["tool_name"] as? String ?? "Tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let (kind, title, detail) = Self.describe(tool: tool, input: input)
            append(sessionId, TimelineEntry(kind: kind, title: title, detail: detail, start: now,
                                            toolUseID: payload["tool_use_id"] as? String, tool: tool))
        case "PostToolUse", "PostToolUseFailure":
            finish(sessionId, toolUseID: payload["tool_use_id"] as? String, tool: payload["tool_name"] as? String,
                   failed: event == "PostToolUseFailure")
        case "Stop":
            closeRunning(sessionId)
            append(sessionId, TimelineEntry(kind: .done, title: L("Turn finished"),
                                            detail: (payload["message"] as? String).map { String($0.prefix(160)) },
                                            start: now, end: now, toolUseID: nil, tool: nil))
        case "StopFailure":
            closeRunning(sessionId)
            append(sessionId, TimelineEntry(kind: .failed, title: L("Turn failed"), detail: nil,
                                            start: now, end: now, failed: true, toolUseID: nil, tool: nil))
        default:
            break
        }
    }

    func recordApproval(_ approval: ApprovalInfo, decision: String) {
        let title: String
        switch decision {
        case "allow": title = L("You allowed")
        case "always": title = L("You always allowed")
        case "deny": title = L("You denied")
        default: title = L("Not answered in time")
        }
        append(approval.sessionId, TimelineEntry(kind: .approval, title: title,
                                                 detail: "\(approval.tool): \(approval.command)".prefix(160).description,
                                                 start: .now, end: .now, failed: decision == "deny",
                                                 toolUseID: nil, tool: decision))
    }

    func recordAutoApproval(sessionId: String, tool: String, command: String, reason: String) {
        append(sessionId, TimelineEntry(kind: .approval, title: L("Auto-allowed"),
                                        detail: "\(tool): \(command) · \(reason)".prefix(200).description,
                                        start: .now, end: .now, toolUseID: nil, tool: "auto"))
    }

    // MARK: Summary and export

    func summary(_ id: String) -> String {
        let list = entries[id] ?? []
        let read = Set(list.filter { $0.kind == .read }.compactMap(\.detail)).count
        let edits = list.filter { $0.kind == .edit || $0.kind == .write }.count
        let commands = list.filter { $0.kind == .command }.count
        let approvals = list.filter { $0.kind == .approval }.count
        var parts = [L("\(read) files read"), L("\(edits) edits"), L("\(commands) commands")]
        if approvals > 0 { parts.append(L("\(approvals) approvals")) }
        if let first = list.first?.start, let last = list.last.map({ $0.end ?? $0.start }) {
            parts.append(Self.format(last.timeIntervalSince(first)))
        }
        return parts.joined(separator: " · ")
    }

    func markdown(_ id: String, project: String) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        var out = "## \(project): Claude Code session\n\n\(summary(id))\n\n"
        for e in entries[id] ?? [] {
            var line = "- `\(e.start.formatted(time))` **\(e.title)**"
            if let d = e.detail { line += ": \(d.replacingOccurrences(of: "\n", with: " "))" }
            if let dur = e.duration, dur >= 0.1, e.kind != .approval { line += " (\(Self.format(dur)))" }
            if e.failed && e.kind != .approval { line += " ⚠︎" }
            out += line + "\n"
        }
        return out
    }

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return m < 60 ? "\(m)m \(s)s" : "\(m / 60)h \(m % 60)m"
    }

    // MARK: Internals

    private func append(_ id: String, _ entry: TimelineEntry) {
        entries[id, default: []].append(entry)
        if entries[id]!.count > maxEntries { entries[id]!.removeFirst(entries[id]!.count - maxEntries) }
        if entries.count > maxSessions,
           let oldest = entries.min(by: { ($0.value.last?.start ?? .distantPast) < ($1.value.last?.start ?? .distantPast) })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    private func finish(_ id: String, toolUseID: String?, tool: String?, failed: Bool) {
        guard var list = entries[id], let i = list.lastIndex(where: {
            $0.end == nil && (toolUseID != nil ? $0.toolUseID == toolUseID : $0.tool == tool)
        }) else { return }
        list[i].end = .now
        list[i].failed = failed
        entries[id] = list
    }

    private func closeRunning(_ id: String) {
        guard var list = entries[id] else { return }
        for i in list.indices where list[i].end == nil { list[i].end = .now }
        entries[id] = list
    }

    private static func describe(tool: String, input: [String: Any]) -> (TimelineEntry.Kind, String, String?) {
        let file = (input["file_path"] ?? input["notebook_path"]) as? String
        let name = file.map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Read": return (.read, L("Read"), name)
        case "Edit", "MultiEdit", "NotebookEdit": return (.edit, L("Edited"), name)
        case "Write": return (.write, L("Wrote"), name)
        case "Bash": return (.command, L("Ran"), (input["command"] as? String).map { String($0.prefix(200)) })
        case "Grep", "Glob", "LS":
            return (.search, L("Searched"), (input["pattern"] ?? input["path"]) as? String)
        case "WebSearch": return (.web, L("Searched the web"), input["query"] as? String)
        case "WebFetch": return (.web, L("Opened"), input["url"] as? String)
        case "Task", "Agent": return (.agent, L("Subagent"), (input["description"] ?? input["prompt"]) as? String)
        default:
            return (.other, tool.hasPrefix("mcp__") ? tool.split(separator: "_").last.map(String.init) ?? tool : tool, nil)
        }
    }
}

// MARK: - View

/// The focused session's timeline, in place of the diff in the live view.
struct TimelinePanel: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = TimelineStore.shared
    @State private var copied = false
    @State private var posting: PostState = .idle
    private enum PostState: Equatable { case idle, sending, done, failed(String) }

    private var linkedIssue: LinearIssue? {
        state.claudeSessions.first { $0.id == state.focusedClaudeSession }?.linear
    }

    private var sessionID: String? { state.focusedClaudeSession }
    private var list: [TimelineEntry] { sessionID.flatMap { store.entries[$0] } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                Text("Timeline").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text(sessionID.map { store.summary($0) } ?? "")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider().overlay(Color.white.opacity(0.06))

            if list.isEmpty {
                Text("Nothing yet. Claude Code's steps for this session show up here.")
                    .font(.system(size: 12)).foregroundColor(Color(hex: "#6B7079"))
                    .padding(12)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(list) { TimelineRow(entry: $0).id($0.id) }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear { if let last = list.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: list.count) { _, _ in
                        if let last = list.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }

            HStack(spacing: 6) {
                if case .failed(let message) = posting {
                    Text(message).font(.system(size: 10.5)).foregroundColor(Color(hex: "#F4505E")).lineLimit(1)
                }
                Spacer()
                if let issue = linkedIssue {
                    SecondaryButton(posting == .done ? L("Posted to \(issue.identifier)")
                                    : posting == .sending ? L("Posting…") : L("Post to \(issue.identifier)")) {
                        guard let id = sessionID, posting != .sending else { return }
                        let body = store.markdown(id, project: state.liveProject ?? "Session")
                        posting = .sending
                        Task {
                            do {
                                try await LinearAPI.comment(on: issue.id, body: body)
                                posting = .done
                            } catch {
                                posting = .failed(error.localizedDescription)
                            }
                        }
                    }
                    .disabled(list.isEmpty)
                    .help("Add this timeline as a comment on \(issue.identifier) · \(issue.title)")
                }
                SecondaryButton(copied ? "Copied" : "Copy as Markdown") {
                    guard let id = sessionID else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.markdown(id, project: state.liveProject ?? "Session"),
                                                   forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(list.isEmpty)
                SecondaryButton("Back to the diff") { state.liveShowsTimeline = false }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.03))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: "#0E0F12"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

private struct TimelineRow: View {
    let entry: TimelineEntry
    private static let time = Date.FormatStyle(date: .omitted, time: .standard)

    private var icon: (String, Color) {
        switch entry.kind {
        case .prompt:   return ("person.fill", Color(hex: "#A78BFA"))
        case .read:     return ("doc.text", Color(hex: "#8E939C"))
        case .search:   return ("magnifyingglass", Color(hex: "#8E939C"))
        case .edit, .write: return ("pencil", Color(hex: "#4C8DFF"))
        case .command:  return ("terminal", Color(hex: "#F5A524"))
        case .web:      return ("globe", Color(hex: "#8E939C"))
        case .agent:    return ("person.2", Color(hex: "#A78BFA"))
        case .approval: return (entry.failed ? "hand.raised.fill" : "checkmark.shield.fill",
                                entry.failed ? Color(hex: "#F4505E") : Color(hex: "#22C55E"))
        case .done:     return ("checkmark.circle.fill", Color(hex: "#22C55E"))
        case .failed:   return ("xmark.octagon.fill", Color(hex: "#F4505E"))
        case .other:    return ("circle.dashed", Color(hex: "#6B7079"))
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.start.formatted(Self.time))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(hex: "#6B7079"))
                .frame(width: 58, alignment: .leading)
            Image(systemName: icon.0)
                .font(.system(size: 10.5))
                .foregroundColor(entry.failed && entry.kind != .approval ? Color(hex: "#F4505E") : icon.1)
                .frame(width: 14)
            Text(entry.title)
                .font(.system(size: 12, weight: entry.kind == .prompt ? .semibold : .medium))
                .foregroundColor(Color(hex: "#E6E8EB"))
                .fixedSize()
            if let detail = entry.detail {
                Text(detail)
                    .font(.system(size: 11.5, design: entry.kind == .command ? .monospaced : .default))
                    .foregroundColor(Color(hex: "#A3A8B0"))
                    .lineLimit(1).truncationMode(.middle)
                    .help(detail)
            }
            Spacer(minLength: 4)
            if entry.running {
                ProgressView().controlSize(.mini)
            } else if let d = entry.duration, d >= 0.1, entry.kind != .approval {
                Text(TimelineStore.format(d))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(d > 30 ? Color(hex: "#F5A524") : Color(hex: "#6B7079"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
    }
}
