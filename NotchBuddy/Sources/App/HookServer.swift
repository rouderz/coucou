import Foundation
import Darwin
import AppKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String { supportDir.appendingPathComponent("nb.sock").path }
    static var hookScriptPath: String {
        #if APPSTORE
        // Written to ~/.claude/coucou/nb-hook via security-scoped bookmark during hook installation
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/coucou/nb-hook").path
        #else
        return supportDir.appendingPathComponent("nb-hook").path
        #endif
    }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private var pendingConnection: (any HookConnection)?   // held open while the user decides
    /// The pending approval came from Mochi's own chat (Allow edits), not a terminal session.
    private var approvalFromChat = false
    private var activeSessionId: String? = nil  // current Claude Code session

    private init() {}

    // MARK: - Start

    /// Where the relays connect (#17): a Unix socket here, a named pipe on Windows.
    private let transport: any HookTransport = UnixSocketTransport(path: HookServer.socketPath)

    func start() {
        #if !APPSTORE
        installHookScript()
        #endif
        transport.start { [weak self] raw, connection in self?.handle(raw, from: connection) }
    }

    // MARK: - Messages (background thread)

    private func handle(_ raw: Data, from connection: any HookConnection) {
        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            connection.reply(#"{"ok":true}"#)
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        // The WhaTicket browser extension checking in (via coucou-native-host): answer with the
        // tickets to accept. Not a Claude Code event — it never touches the sessions.
        if eventName == "WhaTicketBrowser" {
            Task { @MainActor in
                let answer = WhaTicketBridge.shared.handle(payload)
                let line = (try? JSONSerialization.data(withJSONObject: answer))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"commands":[],"interval":30}"#
                Task.detached { connection.reply(line) }
            }
            return
        }

        if eventName == "PermissionRequest" {
            // Keep the connection open: the agent waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(connection, payload: payload) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload) }
            connection.reply(#"{"ok":true}"#)
        }
    }


    // MARK: - Event → AppState
    // All Claude Code events route to the permanent "integration_claude" task.
    // View switches only happen if VS Code is the currently focused mochi.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)
        let agent = payload["agent"] as? String ?? "claude"

        // Remember the projects sessions run in: their .claude/skills show in Settings → Skills.
        if name == "SessionStart" || name == "UserPromptSubmit" { SkillsStore.noteProject(cwd) }

        // Sessions from any terminal count (VS Code, Cursor, iTerm, Terminal, Ghostty, Warp…).

        let focused = state.focusId == "integration_claude"

        // Timeline (#22): every session, on the card or not.
        if name != "StatusLine" { TimelineStore.shared.record(event: name, sessionId: sessionId, payload: payload) }

        // Several sessions (#24): only the focused one drives the card; the others update their record.
        if name != "StatusLine", sessionId != "unknown" {
            let onCard = routeSession(sessionId, project: projectName, cwd: cwd, event: name, agent: agent)
            // Time per Linear issue (#114): every session, on the card or not (local file only).
            TimeTracker.shared.record(hook: name, sessionId: sessionId, cwd: cwd, payload: payload)
            if !onCard {
                updateBackgroundSession(sessionId, event: name, payload: payload)
                return
            }
        }
        defer { if name != "StatusLine" { syncFocusedSession() } }

        switch name {

        case "EditorContext", "EditorAsk":
            // Not a hook: the Coucou editor extension (#58).
            EditorBridge.shared.handle(event: name, payload: payload)
            return

        case "StatusLine":
            // Not a hook: Coucou's status line forwarding Claude Code's status data.
            var usage = PlanUsage()
            func window(_ any: Any?) -> PlanUsage.Window? {
                guard let w = any as? [String: Any],
                      let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                      let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
                let date = Date(timeIntervalSince1970: resets)
                return date > .now ? .init(percent: pct, resetsAt: date) : nil
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                usage.fiveHour = window(limits["five_hour"])
                usage.sevenDay = window(limits["seven_day"])
            }
            // Limits appear only after the session's first reply: keep the last known ones meanwhile.
            if usage.fiveHour == nil, let old = state.planUsage?.fiveHour, old.resetsAt > .now { usage.fiveHour = old }
            if usage.sevenDay == nil, let old = state.planUsage?.sevenDay, old.resetsAt > .now { usage.sevenDay = old }
            if let ctx = payload["context_window"] as? [String: Any],
               let pct = (ctx["used_percentage"] as? NSNumber)?.doubleValue {
                usage.contextPercent = pct
                usage.contextUpdatedAt = .now
            }
            usage.model = (payload["model"] as? [String: Any])?["display_name"] as? String
            usage.plan = state.planUsage?.plan
            state.planUsage = usage
            return

        case "SessionStart":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            nbLog("SessionStart \(projectName) (\(sessionId.prefix(8)))")
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            state.liveActivities = []
            state.liveEdit = nil
            state.liveProject = projectName
            state.updateTask(id: "integration_claude", state: .thinking)
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: "integration_claude", step: String(prompt.prefix(60)))
            }
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            state.updateTask(id: "integration_claude", state: .working)
            let tool = payload["tool_name"] as? String ?? "Tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let step = frenchStep(tool: tool, input: input)
            appendStep(id: "integration_claude", step: step)
            nbLog("PreToolUse \(step)")
            liveStart(tool: tool, input: input, toolUseID: payload["tool_use_id"] as? String,
                      cwd: cwd, project: projectName)

        case "PostToolUse":
            state.updateTask(id: "integration_claude", state: .working)
            liveFinish(payload, status: .done)

        case "PostToolUseFailure":
            state.updateTask(id: "integration_claude", state: .working)
            appendStep(id: "integration_claude", step: "⚠ failed")
            liveFinish(payload, status: .failed)

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: "integration_claude", state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: "integration_claude", state: .question)
                appendStep(id: "integration_claude", step: message)
            }

        case "Stop":
            state.updateTask(id: "integration_claude", state: .finished)
            for i in state.liveActivities.indices where state.liveActivities[i].status == .running {
                state.liveActivities[i].status = .done
            }
            if !state.liveActivities.isEmpty {
                state.liveActivities.append(ToolActivity(tool: "Done", detail: nil, toolUseID: nil, status: .done))
            }
            if let message = Self.stopMessage(payload) {
                appendStep(id: "integration_claude", step: String(message.prefix(60)))
            } else {
                appendStep(id: "integration_claude", step: "Done")
            }
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: "integration_claude", badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                state.updateTask(id: "integration_claude", state: .idle)
                self.clearPillBadge(id: "integration_claude")
            }

        case "StopFailure":
            state.updateTask(id: "integration_claude", state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: "integration_claude", badge: .error)
            }

        case "SessionEnd":
            activeSessionId = nil
            state.updateTask(id: "integration_claude", state: .idle)
            clearSession()
            endSession(sessionId)

        case "SubagentStart":
            appendStep(id: "integration_claude", step: "+ subagent")

        case "SubagentStop":
            appendStep(id: "integration_claude", step: L("• subagent done"))

        default:
            break
        }
    }

    // MARK: - Helpers

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .finished, .error, .confused: isAlert = true
        case .live: isAlert = state.pendingApproval != nil
        default: isAlert = false
        }
        // Do not disturb: never open the island; badge the pill. Approvals still show it, quietly.
        if DoNotDisturb.shared.isActive {
            switch view {
            case .approval, .live where state.pendingApproval != nil:
                setPillBadge(id: "integration_claude", badge: .approval)
                if state.mode == .hidden { NotificationCenter.default.post(name: .hookReveal, object: nil) }
            case .finished: setPillBadge(id: "integration_claude", badge: .finished)
            case .error, .confused: setPillBadge(id: "integration_claude", badge: .error)
            default: break
            }
            return
        }
        if state.mode == .expanded {
            // Only force-switch view for alerts — leave user on their current view otherwise
            if isAlert { state.view = view }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(_ connection: any HookConnection, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)


        let tool = payload["tool_name"] as? String ?? "Tool"
        let command = Self.approvalCommand(tool: tool, input: payload["tool_input"] as? [String: Any] ?? [:])
        // Mochi's own chat asking to edit a file (Allow edits on): approve from the island,
        // without touching the Claude Code session card.
        let fromChat = payload["coucou_internal"] as? Bool == true
        nbLog("PermissionRequest \(tool): \(command)\(fromChat ? " (chat)" : "")")
        if !fromChat { TimeTracker.shared.record(hook: "PermissionRequest", sessionId: sessionId, cwd: cwd, payload: payload) }

        // Auto-approval for this project (#29): answer at once, no island, logged in the timeline.
        do {
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let (risk, reason) = ApprovalRiskClassifier.classify(tool: tool, input: input, cwd: cwd)
            if AutoApprove.shouldAllow(risk: risk, cwd: cwd, fromChat: fromChat) {
                Task.detached { connection.reply(#"{"permissionDecision":"allow"}"#) }
                TimelineStore.shared.recordAutoApproval(sessionId: sessionId, tool: tool, command: command,
                                                        reason: "\(risk.title) · \(reason)")
                return
            }
        }

        // Another request is on screen: wait in line (shown right after the current decision).
        if pendingConnection != nil {
            queueApproval(connection, payload: payload)
            return
        }
        pendingConnection = connection
        approvalFromChat = fromChat
        if !fromChat {
            // Bring the asking session onto the card.
            _ = routeSession(sessionId, project: projectName, cwd: cwd, event: "PermissionRequest",
                             agent: payload["agent"] as? String ?? "claude")
            if state.focusedClaudeSession != sessionId { focusSession(sessionId) }
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            state.updateTask(id: "integration_claude", state: .approval)
            syncFocusedSession()
        }
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let (risk, reason) = ApprovalRiskClassifier.classify(tool: tool, input: toolInput, cwd: cwd)
        let rules = ApprovalRules.describe(payload["permission_suggestions"] as? [[String: Any]] ?? [])
        let approval = ApprovalInfo(sessionId: sessionId, tool: tool, command: command,
                                    risk: risk, riskReason: reason, rules: rules, cwd: cwd)
        state.pendingApproval = approval
        ApprovalShortcuts.shared.arm(for: approval)
        if !fromChat { PhoneAlerts.shared.approvalPending(approval, project: projectName) }
        // File edits get the live view: the diff with Allow / Deny under it.
        let editPreview = EditPreviewBuilder.build(tool: tool, input: payload["tool_input"] as? [String: Any] ?? [:],
                                                   cwd: cwd)
        if let editPreview {
            state.liveEdit = editPreview
            state.liveProject = projectName
        }
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond
        if fromChat {
            state.view = editPreview != nil ? .live : .approval
            NotificationCenter.default.post(name: .hookExpand, object: state.view)
        } else {
            state.focusId = "integration_claude"
            expandIfNeeded(to: editPreview != nil ? .live : .approval)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
            guard let self, self.pendingConnection === connection else { return }
            // "ask" → nb-hook outputs nothing → Claude Code re-asks rather than denying
            self.sendApprovalDecision("ask")
        }
    }

    /// Called by ApprovalView buttons. Writes the decision to the waiting nb-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        let connection = pendingConnection
        pendingConnection = nil

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }

        if let connection {
            Task.detached { connection.reply(json) }
        }

        let state = AppState.shared
        if let approval = state.pendingApproval, !approvalFromChat {
            TimelineStore.shared.recordApproval(approval, decision: decision)
        }
        state.pendingApproval = nil
        ApprovalShortcuts.shared.disarm()
        state.isPinned = false
        defer { showNextQueuedApproval() }
        if approvalFromChat {
            approvalFromChat = false
            state.view = .prompt  // back to the chat, Claude carries on
            return
        }
        state.updateTask(id: "integration_claude", state: .working)
        syncFocusedSession()
        clearPillBadge(id: "integration_claude")
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    /// Updates integration_claude with the current session project name and cwd.
    @MainActor
    private func upsertTask(projectName: String, cwd: String = "") {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].name = projectName
        if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    /// Resets integration_claude to idle, clears steps and project name.
    @MainActor
    private func clearSession() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].steps = []
        state.tasks[idx].stepIndex = 0
        state.tasks[idx].name = "Claude Code"
        state.tasks[idx].pillBadge = nil
    }

    // MARK: - Sessions (#24)

    /// Records the session and decides whether this event drives the card. The focused session
    /// does; another session takes over when the focused one is idle and it starts working.
    @MainActor
    private func routeSession(_ id: String, project: String, cwd: String, event: String,
                              agent: String = "claude") -> Bool {
        let state = AppState.shared
        pruneSessions()
        if let i = state.claudeSessions.firstIndex(where: { $0.id == id }) {
            state.claudeSessions[i].agent = agent
            state.claudeSessions[i].project = project
            if !cwd.isEmpty { state.claudeSessions[i].cwd = cwd }
            state.claudeSessions[i].updatedAt = .now
        } else {
            state.claudeSessions.append(ClaudeSession(id: id, project: project, cwd: cwd, agent: agent))
        }
        // Linear (#27): the issue named by the session's branch (re-checked when a turn starts).
        let turnStart = ["SessionStart", "UserPromptSubmit"].contains(event)
        if turnStart || state.claudeSessions.first(where: { $0.id == id })?.branch == nil {
            LinearLink.refresh(sessionId: id, cwd: cwd, force: turnStart)
        }

        guard let focused = state.focusedClaudeSession,
              let current = state.claudeSessions.first(where: { $0.id == focused }) else {
            focusSession(id)
            return true
        }
        if focused == id { return true }
        let starting = ["SessionStart", "UserPromptSubmit", "PreToolUse"].contains(event)
        let focusedQuiet = ([.idle, .finished, .error] as [BotState]).contains(current.state)
                           && Date.now.timeIntervalSince(current.updatedAt) > 3
        if starting && focusedQuiet && state.pendingApproval == nil {
            focusSession(id)
            return true
        }
        return false
    }

    /// Puts a session on the card (from the chips, an approval, or automatically).
    @MainActor
    func focusSession(_ id: String) {
        let state = AppState.shared
        guard let session = state.claudeSessions.first(where: { $0.id == id }) else { return }
        syncFocusedSession()
        state.focusedClaudeSession = id
        activeSessionId = id
        if let i = state.claudeSessions.firstIndex(where: { $0.id == id }) { state.claudeSessions[i].unseen = false }
        upsertTask(projectName: session.project, cwd: session.cwd)
        if let t = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) {
            state.tasks[t].steps = session.steps
            state.tasks[t].stepIndex = max(0, session.steps.count - 1)
            state.tasks[t].state = session.state
        }
        state.liveActivities = []
        state.liveEdit = nil
        state.liveProject = session.project
    }

    /// Copies the card (steps, state) back into the focused session's record.
    @MainActor
    private func syncFocusedSession() {
        let state = AppState.shared
        guard let id = state.focusedClaudeSession,
              let i = state.claudeSessions.firstIndex(where: { $0.id == id }),
              let task = state.tasks.first(where: { $0.id == "integration_claude" }) else { return }
        state.claudeSessions[i].steps = task.steps
        state.claudeSessions[i].state = task.state
    }

    /// Events from a session that isn't on the card: keep its record current, flag what matters.
    @MainActor
    private func updateBackgroundSession(_ id: String, event: String, payload: [String: Any]) {
        let state = AppState.shared
        guard let i = state.claudeSessions.firstIndex(where: { $0.id == id }) else { return }
        func step(_ text: String) {
            state.claudeSessions[i].steps.append(text)
            if state.claudeSessions[i].steps.count > 20 { state.claudeSessions[i].steps.removeFirst() }
        }
        switch event {
        case "UserPromptSubmit":
            state.claudeSessions[i].state = .thinking
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty { step(String(prompt.prefix(60))) }
        case "PreToolUse":
            state.claudeSessions[i].state = .working
            step(frenchStep(tool: payload["tool_name"] as? String ?? "Tool",
                            input: payload["tool_input"] as? [String: Any] ?? [:]))
        case "PostToolUse", "PostToolUseFailure":
            state.claudeSessions[i].state = .working
        case "Stop":
            state.claudeSessions[i].state = .finished
            state.claudeSessions[i].unseen = true
            step(Self.stopMessage(payload).map { String($0.prefix(60)) } ?? "Done")
            SoundEngine.shared.play("finish")
            setPillBadge(id: "integration_claude", badge: .finished)
        case "StopFailure":
            state.claudeSessions[i].state = .error
            state.claudeSessions[i].unseen = true
            SoundEngine.shared.play("error")
            setPillBadge(id: "integration_claude", badge: .error)
        case "Notification":
            let message = payload["message"] as? String ?? ""
            if message.hasSuffix("?") {
                state.claudeSessions[i].state = .question
                state.claudeSessions[i].unseen = true
                step(message)
            }
        case "SessionEnd":
            endSession(id)
        default:
            break
        }
    }

    /// A session closed: forget it; if it was on the card, show another live one.
    @MainActor
    private func endSession(_ id: String) {
        let state = AppState.shared
        state.claudeSessions.removeAll { $0.id == id }
        guard state.focusedClaudeSession == id else { return }
        state.focusedClaudeSession = nil
        if let next = state.claudeSessions.max(by: { $0.updatedAt < $1.updatedAt }) {
            focusSession(next.id)
        }
    }

    /// Sessions that ended without SessionEnd (terminal closed): drop after 30 min of silence.
    @MainActor
    private func pruneSessions() {
        let state = AppState.shared
        let stale = state.claudeSessions.filter {
            $0.id != state.focusedClaudeSession && Date.now.timeIntervalSince($0.updatedAt) > 30 * 60
        }
        for s in stale { state.claudeSessions.removeAll { $0.id == s.id } }
    }

    // MARK: - Approval queue (several sessions can ask at once)

    private struct QueuedApproval { let connection: any HookConnection; let payload: [String: Any]; let since: Date }
    private var approvalQueue: [QueuedApproval] = []

    @MainActor
    private func queueApproval(_ connection: any HookConnection, payload: [String: Any]) {
        approvalQueue.append(QueuedApproval(connection: connection, payload: payload, since: .now))
        nbLog("PermissionRequest queued (\(approvalQueue.count) waiting)")
        let sessionId = payload["session_id"] as? String ?? ""
        let state = AppState.shared
        if let i = state.claudeSessions.firstIndex(where: { $0.id == sessionId }) {
            state.claudeSessions[i].state = .approval
            state.claudeSessions[i].unseen = true
        }
        // Claude Code gives up after ~120 s: let it re-ask instead of answering too late.
        DispatchQueue.main.asyncAfter(deadline: .now() + 112) { [weak self] in
            guard let self, let i = self.approvalQueue.firstIndex(where: { $0.connection === connection }) else { return }
            self.approvalQueue.remove(at: i)
            Task.detached { connection.reply(#"{"permissionDecision":"ask"}"#) }
        }
    }

    @MainActor
    private func showNextQueuedApproval() {
        guard pendingConnection == nil, !approvalQueue.isEmpty else { return }
        let next = approvalQueue.removeFirst()
        processPermissionRequest(next.connection, payload: next.payload)
    }

    // MARK: - Live view feed

    @MainActor
    private func liveStart(tool: String, input: [String: Any], toolUseID: String?, cwd: String, project: String) {
        let state = AppState.shared
        state.liveProject = project
        for i in state.liveActivities.indices where state.liveActivities[i].status == .running {
            state.liveActivities[i].status = .done
        }
        state.liveActivities.append(ToolActivity(tool: tool, detail: liveDetail(tool: tool, input: input),
                                                 toolUseID: toolUseID))
        if state.liveActivities.count > 30 { state.liveActivities.removeFirst(state.liveActivities.count - 30) }

        if let preview = EditPreviewBuilder.build(tool: tool, input: input, cwd: cwd) {
            state.liveEdit = preview
        }
        // Never force the island open for this; if it's already showing Claude Code, go live.
        if state.mode == .expanded && state.focusId == "integration_claude" && state.view == .overview {
            state.view = .live
        }
    }

    @MainActor
    private func liveFinish(_ payload: [String: Any], status: ToolActivity.Status) {
        let state = AppState.shared
        let id = payload["tool_use_id"] as? String
        let tool = payload["tool_name"] as? String
        if let idx = state.liveActivities.lastIndex(where: {
            $0.status == .running && (id != nil ? $0.toolUseID == id : $0.tool == tool)
        }) {
            state.liveActivities[idx].status = status
        }
    }

    private func liveDetail(tool: String, input: [String: Any]) -> String? {
        if let patch = CodexPatch.text(from: input) {
            return CodexPatch.parse(patch).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
        }
        if let cmd = input["command"] as? String { return String(cmd.prefix(120)) }
        if let file = input["file_path"] as? String { return (file as NSString).lastPathComponent }
        if let path = input["path"] as? String { return (path as NSString).lastPathComponent }
        if let pattern = input["pattern"] as? String { return pattern }
        if let query = input["query"] as? String { return String(query.prefix(80)) }
        if let url = input["url"] as? String { return url }
        return nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    /// The turn's last message: Claude Code sends `message`, Codex `last_assistant_message`.
    static func stopMessage(_ payload: [String: Any]) -> String? {
        for key in ["message", "last_assistant_message"] {
            if let m = payload[key] as? String, !m.isEmpty { return m }
        }
        return nil
    }

    /// What the approval shows: the command, the files a Codex patch edits, or Codex's description.
    static func approvalCommand(tool: String, input: [String: Any]) -> String {
        if let patch = CodexPatch.text(from: input) {
            let files = CodexPatch.parse(patch).map(\.path)
            if !files.isEmpty { return "Edit " + files.joined(separator: ", ") }
        }
        if let cmd = input["command"] as? String { return cmd }
        if let cmd = input["command"] as? [String] { return cmd.joined(separator: " ") }
        if let text = input["description"] as? String, !text.isEmpty { return text }
        return tool
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - French step labels

    private func frenchStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":       "Run",
            "Read":       "Read",
            "Write":      "Write",
            "Edit":       "Edit",
            "Glob":       "Find",
            "Grep":       "Search",
            "WebSearch":  "Web search",
            "WebFetch":   "Fetch",
            "TodoWrite":  "Plan",
            "Task":       "Agent",
            "LS":         "List",
            "MultiEdit":  "Edit",
            "NotebookEdit": "Notebook",
            "apply_patch": "Edit",   // Codex
            "shell":       "Run",
        ]
        let label = labels[tool] ?? tool
        if let patch = CodexPatch.text(from: input) {
            let names = CodexPatch.parse(patch).map { ($0.path as NSString).lastPathComponent }
            return names.isEmpty ? label : "\(label) · \(names.joined(separator: ", "))"
        }
        if let cmd = input["command"] as? String {
            let short = String(cmd.prefix(40))
            return "\(label) · \(short)"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(String(query.prefix(40)))"
        }
        return label
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("nb.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
        }
    }


    /// The nb-hook relay as installed in ~/Library/Application Support (exposed for the tests).
    static var hookScriptSource: String { nbHookScript }

    // MARK: - nb-hook script installation

    /// Claude Code status line command: forwards plan usage to Coucou, then shows the user's own line.
    static var statusLineScriptPath: String { supportDir.appendingPathComponent("coucou-statusline").path }
    /// The status line command the user had before Coucou's, run after ours so it still shows.
    static var previousStatusLinePath: URL { supportDir.appendingPathComponent("statusline-previous") }

    enum HookInstallState: Equatable { case notInstalled, needsUpdate, installed }

    /// Whether Coucou's hooks are in ~/.claude/settings.json, and up to date.
    static func installState() -> HookInstallState {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return .notInstalled }
        let ours = hooks.values.contains { matchers in
            (matchers as? [[String: Any]])?.contains { m in
                (m["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("nb-hook") == true } == true
            } == true
        }
        guard ours else { return .notInstalled }
        return hooksNeedUpdate() ? .needsUpdate : .installed
    }

    /// Whether ~/.claude/settings.json uses Coucou's status line (needed for the plan usage bars).
    static func statusLineInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = settings["statusLine"] as? [String: Any],
              let cmd = line["command"] as? String else { return false }
        return cmd.contains("coucou-statusline")
    }

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires a security-scoped bookmark to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: scriptURL.path
        )
        let statusURL = URL(fileURLWithPath: Self.statusLineScriptPath)
        try? statusLineScript.write(to: statusURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: statusURL.path
        )
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou PermissionRequest hook with timeout < 120s.
    static func hooksNeedUpdate() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any],
              let permReqHooks = hooks["PermissionRequest"] as? [[String: Any]] else {
            return false
        }
        #if !APPSTORE
        // Hooks installed before the plan usage bars existed: offer the update.
        if !statusLineInstalled() { return true }
        #endif
        for matcher in permReqHooks {
            if let hookList = matcher["hooks"] as? [[String: Any]] {
                for hook in hookList {
                    if let cmd = hook["command"] as? String,
                       (cmd.contains("NotchBuddy") || cmd.contains("coucou")),
                       let timeout = hook["timeout"] as? Int,
                       timeout < 120 {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let data = try buildHooksData()
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Backup first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    private func buildHooksData() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        #if APPSTORE
        // Sandboxed apps create quarantined files; /bin/sh bypasses the quarantine flag
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #else
        let quotedCmd = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #endif
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("NotchBuddy") == true || ($0["command"] as? String)?.contains("coucou") == true } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks

        #if !APPSTORE
        // Plan usage bars: Claude Code only gives rate limits to its status line, so Coucou's
        // status line forwards them, then runs the user's previous status line (kept aside).
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        if let previous = statusLine["command"] as? String, !previous.contains("coucou-statusline") {
            try? previous.write(to: Self.previousStatusLinePath, atomically: true, encoding: .utf8)
        }
        statusLine["type"] = "command"
        statusLine["command"] = "\"\(Self.statusLineScriptPath)\""
        settings["statusLine"] = statusLine
        #endif
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }

        #if !APPSTORE
        // Give the status line back to what the user had (or remove ours).
        if let line = settings["statusLine"] as? [String: Any],
           (line["command"] as? String)?.contains("coucou-statusline") == true {
            if let previous = try? String(contentsOf: Self.previousStatusLinePath, encoding: .utf8),
               !previous.isEmpty {
                var restored = line
                restored["command"] = previous
                settings["statusLine"] = restored
            } else {
                settings.removeValue(forKey: "statusLine")
            }
        }
        #endif

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("NotchBuddy") == true ||
                        ($0["command"] as? String)?.contains("coucou") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// App Store variant — needs a security-scoped bookmark URL pointing to ~/.claude
    func previewClaudeHooksAppStore(claudeURL: URL) throws -> String {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let data = try buildHooksData(claudeURL: claudeURL)
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeClaudeHooksAppStore(claudeURL: URL) throws {
        guard let data = _pendingHooksData else { return }
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }

        // Write the nb-hook script into ~/.claude/coucou/nb-hook
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let scriptURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookScriptAppStore.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptURL.path)

        // Write settings.json (with backup)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let backupURL = claudeURL.appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("coucou") == true ||
                        ($0["command"] as? String)?.contains("NotchBuddy") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    private func buildHooksData(claudeURL: URL) throws -> Data {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("coucou") == true ||
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
    #endif
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}

// MARK: - nb-hook Python script content

private let nbHookScript = """
#!/usr/bin/env python3
# nb-hook — Coucou hook relay for Claude Code (and Codex CLI with --agent codex)
# Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
import sys, json, os, socket

def agent_name():
    args = sys.argv[1:]
    if '--agent' in args and args.index('--agent') + 1 < len(args):
        return args[args.index('--agent') + 1]
    return ''

def main():
    # Coucou's own chat runs through Claude Code too: never report its activity,
    # only bring its file-edit approvals back to the island.
    internal = os.environ.get('COUCOU_INTERNAL') == '1'
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return
    agent = agent_name()
    if agent:
        payload['agent'] = agent
    if internal:
        if payload.get('hook_event_name') != 'PermissionRequest':
            return
        payload['coucou_internal'] = True

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    # COUCOU_SOCKET lets the tests talk to a fake Coucou instead of the running app.
    socket_path = os.environ.get('COUCOU_SOCKET') or os.path.expanduser(
        '~/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Let Claude Code persist the rule via updatedPermissions
                    suggestions = payload.get('permission_suggestions') or []
                    decision_obj = {'behavior': 'allow'}
                    if suggestions:
                        decision_obj['updatedPermissions'] = suggestions
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': decision_obj}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Claude Code will handle the absence of output (re-ask or default behaviour)
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

main()
sys.exit(0)
"""

// MARK: - Status line script (plan usage → Coucou)

private let statusLineScript = """
#!/usr/bin/env python3
# coucou-statusline: Claude Code status line for Coucou.
# Forwards the status data (plan usage, context window) to the Coucou app, then prints
# the user's own status line, if they had one before installing Coucou's hooks.
import sys, json, os, socket, subprocess

SUPPORT = os.path.expanduser('~/Library/Application Support/NotchBuddy')

def main():
    raw = sys.stdin.buffer.read()
    try:
        data = json.loads(raw)
        data['hook_event_name'] = 'StatusLine'
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(os.path.join(SUPPORT, 'nb.sock'))
        s.sendall((json.dumps(data) + '\\n').encode())
        s.close()
    except Exception:
        pass
    try:
        with open(os.path.join(SUPPORT, 'statusline-previous')) as f:
            previous = f.read().strip()
    except Exception:
        previous = ''
    if previous:
        try:
            out = subprocess.run(previous, shell=True, input=raw, capture_output=True, timeout=5)
            sys.stdout.buffer.write(out.stdout)
        except Exception:
            pass

main()
"""

// MARK: - nb-hook script for App Store (socket in sandboxed container)

private let nbHookScriptAppStore = """
#!/usr/bin/env python3
# nb-hook — Coucou (App Store) hook relay for Claude Code
# Socket lives inside the sandboxed container; script runs outside the sandbox.
import sys, json, os, socket

def main():
    # Coucou's own chat runs through Claude Code too: never report its activity,
    # only bring its file-edit approvals back to the island.
    internal = os.environ.get('COUCOU_INTERNAL') == '1'
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return
    if internal:
        if payload.get('hook_event_name') != 'PermissionRequest':
            return
        payload['coucou_internal'] = True

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Containers/fr.louisraille.Coucou/Data/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Let Claude Code persist the rule via updatedPermissions
                    suggestions = payload.get('permission_suggestions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

main()
sys.exit(0)
"""
