import Foundation

// MARK: - Time per Linear issue (#114): recording
//
// Feeds the hook events HookServer sees into the local time store (TimeTracking.swift) and keeps
// it for Settings → Time. The session's Linear issue comes from #27 (`ClaudeSession.linear`);
// without one the time goes to "repo @ branch". The file stays in Application Support and is
// never uploaded. Nothing runs between hook events (no timer), so the island stays at 0 % CPU.

/// A half-month period ("1–15" or "16–end"), inclusive YYYY-MM-DD bounds.
struct TimePeriod: Hashable, Identifiable, Sendable {
    let from: String
    let to: String
    var id: String { from }
}

@MainActor
final class TimeTracker: ObservableObject {
    static let shared = TimeTracker()

    @Published private(set) var store: TimeStore
    /// Settings → Time → "Record time per issue". On by default; data stays on this Mac.
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "timeTrackingEnabled") }
    }

    private var saveTask: Task<Void, Never>?
    private nonisolated static let ioQueue = DispatchQueue(label: "fr.louisraille.NotchBuddy.timetracking", qos: .utility)

    private init() {
        store = TimeStore.load()
        enabled = UserDefaults.standard.object(forKey: "timeTrackingEnabled") as? Bool ?? true
    }

    // MARK: Hook events

    /// The time event a hook event stands for; nil when it doesn't change the time.
    nonisolated static func kind(hook name: String, payload: [String: Any]) -> TimeEvent.Kind? {
        switch name {
        case "SessionStart": return .start
        case "UserPromptSubmit": return .prompt
        case "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop", "PermissionRequest":
            return .activity
        case "Stop", "StopFailure", "SessionEnd": return .stop
        case "Notification":
            // Claude Code waiting for the user after a while: the session is idle.
            let type = payload["notification_type"] as? String ?? ""
            let message = (payload["message"] as? String ?? "").lowercased()
            return type == "idle_prompt" || message.contains("waiting for your input") ? .idle : nil
        default: return nil
        }
    }

    /// Called by HookServer for every hook event, once the session is known.
    func record(hook name: String, sessionId: String, cwd: String, payload: [String: Any]) {
        guard enabled, !sessionId.isEmpty, sessionId != "unknown",
              let kind = Self.kind(hook: name, payload: payload) else { return }
        let at = Date.now
        let knownBranch = AppState.shared.claudeSessions.first { $0.id == sessionId }?.branch
        if knownBranch == nil, !cwd.isEmpty, needsBranch(cwd) {
            // No Linear link (or not yet): look the branch up once a minute per folder, so time
            // without an issue goes to "repo @ branch" from the first event.
            branchCache[cwd] = (branchCache[cwd]?.branch, at)
            Task { @MainActor in
                let branch = await LinearLink.gitBranch(in: cwd)
                self.branchCache[cwd] = (branch, Date.now)
                self.append(kind, sessionId: sessionId, cwd: cwd, at: at)
            }
            return
        }
        append(kind, sessionId: sessionId, cwd: cwd, at: at)
    }

    private var branchCache: [String: (branch: String?, at: Date)] = [:]

    private func needsBranch(_ cwd: String) -> Bool {
        guard let hit = branchCache[cwd] else { return true }
        return Date.now.timeIntervalSince(hit.at) > 60
    }

    private func append(_ kind: TimeEvent.Kind, sessionId: String, cwd: String, at: Date) {
        let session = AppState.shared.claudeSessions.first { $0.id == sessionId }
        let repo = URL(fileURLWithPath: cwd).lastPathComponent
        let event = TimeEvent(session: sessionId, kind: kind, at: at,
                              issue: session?.linear.map { TimeIssue(identifier: $0.identifier, title: $0.title) },
                              repo: repo.isEmpty ? nil : repo,
                              branch: session?.branch ?? branchCache[cwd]?.branch)
        store.record(event)
        scheduleSave()
    }

    // MARK: Views

    /// Tracked time plus manual edits; a session still running counts up to now.
    func rows(now: Date = .now) -> [TimeRow] {
        store.rows(now: now)
    }

    /// A manual +/- (or a new entry for work outside Claude Code) on a day.
    func adjust(day: String, key: String, seconds: TimeInterval, title: String? = nil) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, seconds != 0 else { return }
        store.adjust(TimeAdjustment(day: day, key: key, deltaSeconds: seconds, title: title))
        scheduleSave()
    }

    // MARK: Periods

    /// The current half-month and the ones before it, newest first.
    nonisolated static func recentPeriods(before date: Date, count: Int, calendar: Calendar = .current) -> [TimePeriod] {
        var out: [TimePeriod] = []
        var d = date
        for _ in 0..<max(0, count) {
            let p = TimeTracking.halfMonth(of: d, calendar: calendar)
            out.append(TimePeriod(from: p.from, to: p.to))
            guard let start = day(p.from, calendar: calendar),
                  let previous = calendar.date(byAdding: .day, value: -1, to: start) else { break }
            d = previous
        }
        return out
    }

    /// Noon of a YYYY-MM-DD day (noon: no daylight-saving edge).
    nonisolated static func day(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// "1h 05m"
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return String(format: "%dh %02dm", m / 60, m % 60)
    }

    // MARK: File

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the store off the main thread, in order.
    func saveNow() {
        saveTask = nil
        let snapshot = store
        Self.ioQueue.async { try? snapshot.save() }
    }

    /// The app is quitting: writes what is still waiting for the debounce, and waits for it.
    func flush() {
        guard let pending = saveTask else { return }
        pending.cancel()
        saveTask = nil
        let snapshot = store
        Self.ioQueue.sync { try? snapshot.save() }
    }
}
