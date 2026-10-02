import AppKit
import os

// MARK: - Model

struct LinearIssue: Identifiable, Equatable, Sendable {
    let id: String
    let identifier: String      // "SHO-123"
    let title: String
    let url: String
    let branchName: String?
    let stateName: String
    let stateType: String       // backlog, unstarted, started, completed, canceled
    let stateColor: String      // "#f2c94c"
    let priority: Int           // 0 none, 1 urgent … 4 low
    let updatedAt: Date?

    init?(_ node: [String: Any]) {
        guard let id = node["id"] as? String, let identifier = node["identifier"] as? String,
              let title = node["title"] as? String else { return nil }
        let state = node["state"] as? [String: Any]
        self.id = id
        self.identifier = identifier
        self.title = title
        self.url = node["url"] as? String ?? "https://linear.app"
        self.branchName = node["branchName"] as? String
        self.stateName = state?["name"] as? String ?? ""
        self.stateType = state?["type"] as? String ?? ""
        self.stateColor = state?["color"] as? String ?? "#8E939C"
        self.priority = node["priority"] as? Int ?? 0
        self.updatedAt = (node["updatedAt"] as? String).flatMap { LinearAPI.date($0) }
    }
}

// MARK: - API (#26)

/// Linear's GraphQL API with a personal API key (Settings → Integrations → Linear).
enum LinearAPI {
    static let keychainKey = "linear-api-key"
    private static let endpoint = URL(string: "https://api.linear.app/graphql")!
    private static let issueFields = "id identifier title url priority branchName updatedAt state { name type color }"

    enum Failure: LocalizedError {
        case noKey, http(Int), graphQL(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return L("Add your Linear API key in Settings")
            case .http(401), .http(400): return L("Invalid API key (401)")
            case .http(let code): return code == 0 ? L("Can't reach Linear") : L("API error \(code)")
            case .graphQL(let message): return message
            }
        }
    }

    static var hasKey: Bool { !(Secrets.store.get(keychainKey) ?? "").isEmpty }

    static func query(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard let key = Secrets.store.get(keychainKey), !key.isEmpty else { throw Failure.noKey }
        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: req)
        PollGate.shared.record("integration_linear", response)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            if code == 400 || code == 401 { throw Failure.http(401) }
            throw Failure.graphQL(first["message"] as? String ?? "Linear error")
        }
        guard code == 200, let payload = json["data"] as? [String: Any] else { throw Failure.http(code) }
        return payload
    }

    /// Your open issues, most recently updated first.
    static func assignedIssues() async throws -> [LinearIssue] {
        let q = """
        query { viewer { assignedIssues(first: 25, orderBy: updatedAt,
          filter: { state: { type: { nin: ["completed", "canceled"] } } }) { nodes { \(issueFields) } } } }
        """
        let data = try await query(q)
        let nodes = ((data["viewer"] as? [String: Any])?["assignedIssues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap(LinearIssue.init)
    }

    /// One issue by identifier ("SHO-123"); nil when it doesn't exist or isn't visible to you.
    static func issue(_ identifier: String) async -> LinearIssue? {
        let q = "query($id: String!) { issue(id: $id) { \(issueFields) } }"
        guard let data = try? await query(q, variables: ["id": identifier]),
              let node = data["issue"] as? [String: Any] else { return nil }
        return LinearIssue(node)
    }

    /// Posts Markdown as a comment on the issue (#27: the session's timeline).
    static func comment(on issueID: String, body: String) async throws {
        let q = "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success } }"
        let data = try await query(q, variables: ["issueId": issueID, "body": body])
        guard (data["commentCreate"] as? [String: Any])?["success"] as? Bool == true else {
            throw Failure.graphQL(L("Linear didn't accept the comment"))
        }
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - Poller

@MainActor
final class LinearPoller {
    static let shared = LinearPoller()
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard PollGate.shared.allow("integration_linear", every: 300) else { return }
                LinearPoller.shared.pollNow()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { LinearPoller.shared.pollNow() }
    }

    func pollNow() {
        guard LinearAPI.hasKey else { return }
        Task { @MainActor in
            let state = AppState.shared
            do {
                state.linearIssues = try await LinearAPI.assignedIssues()
                state.linearError = nil
            } catch {
                state.linearError = error.localizedDescription
            }
            state.linearLoaded = true
        }
    }
}

// MARK: - Session ↔ issue (#27)

/// Links a Claude Code session to the Linear issue in its git branch ("wolfgang/sho-123-fix-cart").
@MainActor
enum LinearLink {
    private static var checkedBranch: [String: String] = [:]   // session → branch last looked at
    private static var lastTry: [String: Date] = [:]
    private static let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")

    /// Called on session activity; does work only when the branch changed. Without `force`
    /// (any hook event), at most once a minute per session.
    static func refresh(sessionId: String, cwd: String, force: Bool = false) {
        guard LinearAPI.hasKey, !cwd.isEmpty else { return }
        if !force, let last = lastTry[sessionId], Date.now.timeIntervalSince(last) < 60 { return }
        lastTry[sessionId] = .now
        Task { @MainActor in
            guard let branch = await gitBranch(in: cwd), checkedBranch[sessionId] != branch else { return }
            checkedBranch[sessionId] = branch
            let issue = await issue(forBranch: branch)
            let state = AppState.shared
            guard let i = state.claudeSessions.firstIndex(where: { $0.id == sessionId }) else { return }
            state.claudeSessions[i].branch = branch
            state.claudeSessions[i].linear = issue
            if let issue { log.info("session linked to \(issue.identifier, privacy: .public) (\(branch, privacy: .public))") }
        }
    }

    /// "SHO-123" candidates in a branch name, most likely first.
    nonisolated static func identifiers(inBranch branch: String) -> [String] {
        let pattern = #"(?i)(?:^|[/_-])([a-z][a-z0-9]{1,9})-(\d{1,6})(?=$|[/_-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = branch as NSString
        return regex.matches(in: branch, range: NSRange(location: 0, length: ns.length)).map {
            "\(ns.substring(with: $0.range(at: 1)).uppercased())-\(ns.substring(with: $0.range(at: 2)))"
        }
    }

    private static func issue(forBranch branch: String) async -> LinearIssue? {
        let state = AppState.shared
        // Your assigned issues first (no request), by branch name or identifier.
        if let known = state.linearIssues.first(where: { $0.branchName == branch }) { return known }
        for id in identifiers(inBranch: branch) {
            if let known = state.linearIssues.first(where: { $0.identifier == id }) { return known }
            if let fetched = await LinearAPI.issue(id) { return fetched }
        }
        return nil
    }

    private static func gitBranch(in cwd: String) async -> String? {
        await Task.detached(priority: .utility) {
            guard let out = CLITool.run("/usr/bin/git", ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
                                        environment: ProcessInfo.processInfo.environment, timeout: 5),
                  out.status == 0 else { return nil }
            let branch = String(decoding: out.stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.isEmpty || branch == "HEAD" ? nil : branch
        }.value
    }
}
