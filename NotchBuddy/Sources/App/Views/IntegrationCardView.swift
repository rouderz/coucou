import SwiftUI

// The integration card (Claude Code, GitHub, Vercel…): status, plan usage, sessions.

// MARK: - Integration card (overview left card when an integration pill is focused)

struct IntegrationCardView: View {
    let task: AgentTask
    @Binding var showingDetail: Bool
    @ObservedObject private var appState = AppState.shared

    private var isConfigured: Bool {
        switch task.id {
        case "integration_claude":
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any],
                  let ss = hooks["SessionStart"] as? [[String: Any]] else { return false }
            return ss.contains { ($0["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false }
        case "integration_resend":  return Secrets.store.get("resend-api-key") != nil
        case "integration_n8n":     return Secrets.store.get("n8n-api-key")    != nil
        case "integration_vercel":  return Secrets.store.get("vercel-token")   != nil
        case "integration_github":  return AppState.shared.githubConnection.isConnected
                                        || Secrets.store.get("github-token") != nil
        case "integration_stripe":  return Secrets.store.get("stripe-api-key") != nil
        case "integration_notion":  return Secrets.store.get("notion-api-key") != nil
        case "integration_calcom":  return Secrets.store.get("calcom-api-key") != nil
        case "integration_linear":  return LinearAPI.hasKey
        case "integration_whaticket": return BrowserExtension.isSetUp
        case "integration_gmail": return GoogleAPI.isConnected
        case "integration_ci":    return AppState.shared.githubConnection.isConnected
                                      || Secrets.store.get("github-token") != nil
        default: return false
        }
    }

    /// Claude Code status line: whether Coucou's hooks are in ~/.claude/settings.json.
    private var claudeHookStatus: (text: String, color: Color) {
        isConfigured
            ? (L("Hooks installed"), Color(hex: "#22C55E"))
            : (L("Hooks not installed · install them in Settings"), Color(hex: "#F4505E"))
    }

    private var openURL: URL? {
        switch task.id {
        case "integration_claude":  return nil  // uses terminal button below
        case "integration_resend":  return URL(string: "https://resend.com/emails")
        case "integration_n8n":
            if let s = Secrets.store.get("n8n-url") { return URL(string: s) }
            return nil
        case "integration_vercel":  return URL(string: "https://vercel.com/dashboard")
        case "integration_github":  return URL(string: "https://github.com")
        case "integration_stripe":  return URL(string: "https://dashboard.stripe.com/payments")
        case "integration_notion":  return URL(string: "https://www.notion.so")
        case "integration_calcom":  return URL(string: "https://app.cal.com/bookings")
        case "integration_linear":  return URL(string: "https://linear.app")
        case "integration_whaticket": return WhaTicketRules.webURL(nil)
        case "integration_gmail": return URL(string: "https://mail.google.com")
        case "integration_ci":    return URL(string: "https://github.com/pulls")
        default: return nil
        }
    }

    // Claude Code with an active session: show ticker layout (same as overview)
    private var vsCodeSessionActive: Bool {
        task.id == "integration_claude" && (task.state != .idle || !task.steps.isEmpty)
    }

    // n8n with a finished execution: show result row instead of "Open n8n" button
    private var n8nHasActivity: Bool {
        task.id == "integration_n8n" && !task.steps.isEmpty &&
        (task.state == .finished || task.state == .error)
    }

    // Vercel with recent deployments
    private var vercelHasActivity: Bool {
        task.id == "integration_vercel" && !appState.vercelDeployments.isEmpty
    }

    // Resend with recent emails
    private var resendHasData: Bool {
        task.id == "integration_resend" && !appState.resendEmails.isEmpty
    }

    // GitHub with stats loaded
    private var githubHasData: Bool {
        task.id == "integration_github" && appState.githubStats != nil
    }

    // Stripe: show card as soon as first poll completes (balance OR payments)
    private var stripeHasData: Bool {
        task.id == "integration_stripe" && appState.stripeLoaded
    }

    // Cal.com: show calendar as soon as first poll completes
    private var calcomHasData: Bool {
        task.id == "integration_calcom" && appState.calcomLoaded
    }

    // Notion: show pages as soon as first poll completes
    private var notionHasData: Bool {
        task.id == "integration_notion" && (appState.notionLoaded || appState.notionError != nil)
    }

    var body: some View {
        if showingDetail && n8nHasActivity {
            N8nDetailView(task: task) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { showingDetail = false }
            }
            .transition(.opacity)
        } else if showingDetail && vercelHasActivity {
            VercelDetailView(deployment: appState.vercelDeployments[0]) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { showingDetail = false }
            }
            .transition(.opacity)
        } else if vercelHasActivity {
            VercelDeploymentListView(deployments: appState.vercelDeployments, onOpenDetail: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { showingDetail = true }
            })
            .transition(.opacity)
        } else if resendHasData {
            ResendCardView(emails: appState.resendEmails, total: appState.resendTotal)
                .transition(.opacity)
        } else if githubHasData {
            GitHubStatsCardView(stats: appState.githubStats!, connection: appState.githubConnection)
                .transition(.opacity)
        } else if stripeHasData {
            StripeCardView()
                .transition(.opacity)
        } else if calcomHasData {
            CalcomCardView()
                .transition(.opacity)
        } else if notionHasData {
            NotionCardView()
                .transition(.opacity)
        } else if task.id == "integration_linear" && (appState.linearLoaded || appState.linearError != nil) {
            LinearCardView()
                .transition(.opacity)
        } else if task.id == "integration_whaticket" && appState.whaticketLoaded {
            WhaTicketCardView()
                .transition(.opacity)
        } else if task.id == "integration_gmail" && appState.gmailLoaded {
            GmailCardView()
                .transition(.opacity)
        } else if task.id == "integration_ci" && (appState.ciLoaded || appState.ciError != nil) {
            CICardView()
                .transition(.opacity)
        } else if vsCodeSessionActive {
            // Active session view — reuse overview layout
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: task.color))
                        .frame(width: 7, height: 7)
                    if task.id == "integration_claude" && appState.claudeSessions.count > 1 {
                        SessionSwitcher()  // several Claude Code sessions: pick the one on the card
                    } else {
                        Text(task.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(1)
                        if let issue = appState.claudeSessions.first(where: { $0.id == appState.focusedClaudeSession })?.linear {
                            LinearIssueChip(issue: issue)
                        } else {
                            Text("Claude Code")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#8E939C"))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 2)
                    if task.steps.count > 1 {
                        Text("\(min(task.stepIndex + 1, task.steps.count))/\(task.steps.count)")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#6B7079"))
                            .fixedSize()
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 108)
                .padding(.trailing, 62)  // room for the ✎ and ↗ buttons

                TickerView(task: task)
                    .frame(height: 44)
                    .padding(.top, 6)
                    .padding(.leading, 108)
                    .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 4)
        } else {
            // Idle / not connected view — slides in from left when returning from detail
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: task.color))
                        .frame(width: 7, height: 7)
                    Text(task.id == "integration_claude" ? "Claude Code" : task.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Text("Integration")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                    Spacer(minLength: 2)
                }
                .padding(.top, 6)
                .padding(.leading, 108)
                .padding(.trailing, 36)

                // Focus timer (#119): a running block takes the place of the usage bars.
                if task.id == "integration_claude" && appState.focus.phase != .idle {
                    FocusCardPanel()
                        .padding(.leading, 108)
                        .padding(.trailing, 16)
                        .padding(.top, 2)
                } else if task.id == "integration_claude" && isConfigured {
                    // Claude Code with hooks installed: the plan usage bars say more than L("Hooks installed").
                    PlanUsageView(usage: appState.planUsage)
                        .padding(.leading, 108)
                        .padding(.trailing, 16)
                        .padding(.top, 4)
                } else {
                    HStack(spacing: 5) {
                        let status: (text: String, color: Color) = task.id == "integration_claude"
                            ? claudeHookStatus
                            : { let st = IntegrationStatus.of(task.id, appState)
                                return (st.help, Color(hex: st.colorHex)) }()
                        let dot = status.color
                        let label = status.text
                        Circle().fill(dot).frame(width: 5, height: 5)
                        Text(LocalizedStringKey(label))
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                    .padding(.leading, 108)
                    .padding(.top, 2)
                }

                HStack(spacing: 8) {
                    if task.id == "integration_claude" {
                        if let editor = Editor.preferred(appState.preferredEditor) {
                            Button("Open in \(editor.name)") { editor.open(folder: task.sessionCwd) }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: task.color).opacity(0.7))
                                .buttonStyle(.plain)
                        } else if let cwd = task.sessionCwd, !cwd.isEmpty {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: task.color).opacity(0.7))
                            .buttonStyle(.plain)
                        }
                        if appState.focus.phase == .idle {
                            FocusStartButton()
                        }
                    } else if n8nHasActivity {
                        // Clickable pill — tap to open execution detail
                        let success = task.state == .finished
                        let accent  = success ? Color(hex: "#22C55E") : Color(hex: "#F4505E")
                        Button(action: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { showingDetail = true }
                        }) {
                            HStack(spacing: 5) {
                                Circle().fill(accent).frame(width: 5, height: 5)
                                Text(task.steps.first ?? "Workflow")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#C5C8CD"))
                                    .lineLimit(1).truncationMode(.tail)
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(Color(hex: "#6B7079"))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(accent.opacity(0.1))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(accent.opacity(0.22), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    } else if let url = openURL {
                        Button("Open \(task.name)") { AppLinks.open(url) }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: task.color).opacity(0.85))
                            .buttonStyle(.plain)
                    }
                    if task.id == "integration_stripe" {
                        if isConfigured {
                            Button("Refresh") { Task { @MainActor in StripePoller.shared.pollNow() } }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#0570DE").opacity(0.85))
                                .buttonStyle(.plain)
                        }
                    }
                    if task.id == "integration_calcom" && isConfigured {
                        Button("Refresh") { Task { @MainActor in CalcomPoller.shared.pollNow() } }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#C9956A").opacity(0.85))
                            .buttonStyle(.plain)
                    }
                    if !isConfigured {
                        Button("Settings…") {
                            NotificationCenter.default.post(name: .openFullSettings, object: nil)
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 108)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 4)
            .transition(.opacity)
        }
    }

}

// MARK: - Notion Card View

/// Small ↻ button that re-polls one integration and spins for a moment.
/// The integration's status light: green connected, amber nothing to show yet,
/// red error / not configured, grey checking. Hover for details.
struct StatusDot: View {
    let id: String
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        let status = IntegrationStatus.of(id, appState)
        Circle()
            .fill(Color(hex: status.colorHex))
            .frame(width: 7, height: 7)
            .help(status.help)
    }
}

struct RefreshButton: View {
    let id: String
    @State private var spins = 0

    var body: some View {
        Button {
            spins += 1
            IntegrationRefresher.refresh(id)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(Color(hex: "#5F646D"))
                .rotationEffect(.degrees(Double(spins) * 360))
                .animation(.easeInOut(duration: 0.8), value: spins)
                .frame(width: 16, height: 16)
                .background(Color.white.opacity(0.07))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Refresh")
    }
}

struct NotionHint: View {
    let dot: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Circle().fill(Color(hex: dot)).frame(width: 5, height: 5).padding(.top, 4)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        }
        .padding(.top, 8)
        .padding(.leading, 108)
        .padding(.trailing, 16)
    }
}


// MARK: - Claude plan usage

/// 5-hour and weekly plan limits, as Claude Code reports them to its status line.
struct PlanUsageView: View {
    let usage: PlanUsage?

    var body: some View {
        if let usage, usage.fiveHour != nil || usage.sevenDay != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let w = usage.fiveHour {
                    UsageBar(label: "5h", window: w, reset: L("resets in ") + Self.remaining(until: w.resetsAt))
                }
                if let w = usage.sevenDay {
                    UsageBar(label: L("Week"), window: w, reset: L("resets ") + Self.dayTime(w.resetsAt))
                }
                // Context of the Claude Code session running now (stale after 15 min without updates).
                if let pct = usage.contextPercent, let at = usage.contextUpdatedAt,
                   Date.now.timeIntervalSince(at) < 15 * 60 {
                    UsageBar(label: L("Context"), window: .init(percent: pct, resetsAt: at),
                             reset: pct >= 80 ? L("/compact soon") : (usage.model ?? L("this session")))
                }
            }
        } else {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: "#22C55E")).frame(width: 5, height: 5)
                Text(HookServer.statusLineInstalled()
                     ? L("Hooks installed · usage shows after your next Claude message")
                     : L("Hooks installed · update them in Settings to see plan usage"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(2)
            }
        }
    }

    static func remaining(until date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func dayTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'today' HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }
}

struct UsageBar: View {
    let label: String
    let window: PlanUsage.Window
    let reset: String

    private var color: Color {
        window.percent >= 90 ? Color(hex: "#F4505E")
            : window.percent >= 75 ? Color(hex: "#F5A524")
            : Color(hex: "#4C8DFF")
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color)
                        .frame(width: max(3, geo.size.width * min(1, window.percent / 100)))
                }
            }
            .frame(height: 5)
            Text("\(Int(window.percent.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(Color(hex: "#F5F6F8"))
                .frame(width: 34, alignment: .trailing)
            Text(reset)
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "#6B7079"))
                .lineLimit(1)
                .fixedSize()
        }
    }
}


// MARK: - Several Claude Code sessions (#24)

/// One chip per running session, coloured by state; click to put it on the card.
/// A dot marks sessions that finished, failed or asked something while off the card.
struct SessionSwitcher: View {
    @ObservedObject private var state = AppState.shared
    private let maxChips = 3

    var body: some View {
        let sessions = state.claudeSessions
        HStack(spacing: 4) {
            ForEach(sessions.prefix(maxChips)) { session in
                SessionChip(session: session, focused: session.id == state.focusedClaudeSession)
            }
            if sessions.count > maxChips {
                Menu {
                    ForEach(sessions.dropFirst(maxChips)) { session in
                        Button(session.project) { HookServer.shared.focusSession(session.id) }
                    }
                } label: {
                    Text("+\(sessions.count - maxChips)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

struct SessionChip: View {
    let session: ClaudeSession
    let focused: Bool
    @State private var hover = false

    private var color: Color {
        switch session.state {
        case .working, .searching: return Color(hex: "#4C8DFF")
        case .thinking:            return Color(hex: "#A78BFA")
        case .approval, .question: return Color(hex: "#F5A524")
        case .error, .ratelimit:   return Color(hex: "#F4505E")
        case .finished:            return Color(hex: "#22C55E")
        default:                   return Color(hex: "#6B7079")
        }
    }

    var body: some View {
        Button { HookServer.shared.focusSession(session.id) } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                if session.agent != "claude", let agent = Agents.named(session.agent) {
                    Text(agent.name)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#10A37F"))
                }
                Text(session.project)
                    .font(.system(size: 11, weight: focused ? .semibold : .regular))
                    .foregroundColor(Color(hex: focused ? "#F5F6F8" : "#A3A8B0"))
                    .lineLimit(1)
                    .frame(maxWidth: 90)
                if session.unseen && !focused {
                    Circle().fill(Color(hex: "#F5F6F8")).frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.white.opacity(focused ? 0.14 : hover ? 0.08 : 0.04))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(session.cwd)
    }
}
