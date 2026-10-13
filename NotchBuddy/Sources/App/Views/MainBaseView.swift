import AppKit
import SwiftUI

// The main character's base in design C (with the character rail): the Claude Code sessions as
// rows, the plan usage, then chips for Focus, the editor and the integrations that don't have a
// character of their own.

struct MainBaseView: View {
    @ObservedObject var state: AppState

    /// The main character's base shows Claude Code unless one of its integrations was picked
    /// from the chips.
    static func showsClaude(_ state: AppState) -> Bool {
        guard let task = state.focusTask else { return true }
        return task.id == "integration_claude" || (!task.isIntegration && task.source == .claudeCode)
    }

    private var sessions: [ClaudeSession] {
        Array(state.claudeSessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(2))
    }

    /// The integrations the main character looks after (no character of their own).
    private var others: [AgentTask] {
        state.tasks.filter { $0.isIntegration && $0.id != "integration_claude" && state.critterAssignments[$0.id] == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sessions.isEmpty {
                row(dot: Color(hex: "#6B7079"), title: "Claude Code",
                    detail: L("No session right now — start one in your terminal"), badge: nil) {}
            } else {
                ForEach(sessions) { s in
                    row(dot: SessionChip.color(for: s.state), title: s.project,
                        detail: s.steps.last ?? s.branch ?? (s.cwd as NSString).abbreviatingWithTildeInPath,
                        badge: s.state == .approval && state.pendingApproval != nil ? L("Approve") : nil) {
                        HookServer.shared.focusSession(s.id)
                        if s.state == .approval && state.pendingApproval != nil {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .approval }
                        }
                    }
                }
            }

            if state.focus.phase != .idle {
                FocusCardPanel()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.045)))
            } else {
                PlanUsageView(usage: state.planUsage)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.045)))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let editor = Editor.preferred(state.preferredEditor) {
                        chip(L("Open in \(editor.name)"), color: Color(hex: "#C5C8CD")) {
                            editor.open(folder: state.tasks.first { $0.id == "integration_claude" }?.sessionCwd)
                        }
                    }
                    if state.focus.phase == .idle {
                        chip(L("Focus"), color: Color(hex: "#E8C27A")) { FocusTimer.shared.start() }
                    }
                    if state.inboxEnabled, !InboxStore.shared.items.isEmpty {
                        chip(L("Inbox · \(InboxStore.shared.items.count)"), color: Color(hex: "#C5C8CD")) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .inbox }
                        }
                    }
                    ForEach(others) { t in
                        let summary = t.steps.first.map { " · \($0)" } ?? ""
                        chip("\(t.name)\(summary)", color: Color(hex: "#C5C8CD"), dot: Color(hex: t.color)) {
                            state.setFocus(t.id)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(dot: Color, title: String, detail: String, badge: String?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#9A9EA6"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let badge {
                    Text(verbatim: badge)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(Color(hex: "#F5B651"))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: "#3A2E1C")))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ text: String, color: Color, dot: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(verbatim: text).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 9).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}
