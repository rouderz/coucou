import Foundation

/// CI pill (#115): GitHub Actions status of your open PRs. Pure logic only (check-run
/// aggregation, pill state, polling interval, failed-log tail), no network and no UI.
/// Mirrors windows/src/core/ci.ts; keep both in step.
enum CheckState: Sendable, Equatable { case running, passed, failed, cancelled, skipped, neutral }

/// A PR (or commit) as a whole. `.neutral` also covers "only skipped checks".
enum PRCIState: Sendable, Equatable { case running, passed, failed, cancelled, neutral }

/// The fields we use from `GET /repos/{o}/{r}/commits/{sha}/check-runs`.
struct CheckRun: Sendable, Equatable {
    var id: Int
    var name: String
    var status: String          // queued | in_progress | completed | waiting | pending | requested
    var conclusion: String?     // success | failure | neutral | cancelled | skipped | timed_out | action_required | stale | startup_failure
    var startedAt: Date?
    var completedAt: Date?
    var htmlURL: String?

    /// Parses one element of the `check_runs` array. Nil without id, name or status.
    static func parse(_ d: [String: Any]) -> CheckRun? {
        guard let id = d["id"] as? Int, let name = d["name"] as? String, let status = d["status"] as? String else { return nil }
        return CheckRun(id: id, name: name, status: status, conclusion: d["conclusion"] as? String,
                        startedAt: (d["started_at"] as? String).flatMap(CICore.date),
                        completedAt: (d["completed_at"] as? String).flatMap(CICore.date),
                        htmlURL: d["html_url"] as? String)
    }

    var state: CheckState {
        guard status == "completed" else { return .running }
        switch conclusion {
        case "success": return .passed
        case "failure", "timed_out", "startup_failure": return .failed
        case "cancelled": return .cancelled
        case "skipped": return .skipped
        default: return .neutral  // neutral, stale, action_required (waits for a person), unknown
        }
    }

    /// Seconds it took (up to `now` while still running); nil when unknown.
    func durationSeconds(now: Date = Date()) -> Int? {
        guard let startedAt else { return nil }
        return max(0, Int((((completedAt ?? now).timeIntervalSince(startedAt))).rounded()))
    }
}

struct CommitSummary: Sendable, Equatable {
    var state: PRCIState
    var running = 0, passed = 0, failed = 0
    var other = 0   // cancelled + skipped + neutral
    var total = 0
}

/// A PR (or watched branch) with the summary of its head commit's checks.
struct PRCI: Sendable, Equatable {
    var key: String    // "owner/repo#123", or "owner/repo@branch"
    var sha: String
    var summary: CommitSummary
}

enum PillColor: Sendable, Equatable { case idle, running, failed, passed }
struct PillState: Sendable, Equatable { var color: PillColor; var count: Int }

struct PillMemory: Sendable, Equatable {
    var states: [String: (sha: String, state: PRCIState)] = [:]
    var greenUntil: Date = .distantPast

    static func == (a: PillMemory, b: PillMemory) -> Bool {
        a.greenUntil == b.greenUntil && a.states.count == b.states.count
            && a.states.allSatisfy { b.states[$0.key]?.sha == $0.value.sha && b.states[$0.key]?.state == $0.value.state }
    }
}

struct CIEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case failed, passed }
    var kind: Kind
    var key: String
    var sha: String
}

enum CICore {
    static let greenSeconds: TimeInterval = 8
    static let fastInterval: TimeInterval = 30
    static let slowInterval: TimeInterval = 300
    static let maxBackoff: TimeInterval = 30 * 60

    /// Formatters are built per call: ISO8601DateFormatter isn't Sendable, so Swift 6 refuses a shared static one.
    static func date(_ text: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Re-runs list a check twice: keep the newest run of each name.
    static func latestRuns(_ runs: [CheckRun]) -> [CheckRun] {
        var byName: [String: CheckRun] = [:]
        for r in runs {
            if let prev = byName[r.name] {
                let a = r.startedAt ?? .distantPast, b = prev.startedAt ?? .distantPast
                if a > b || (a == b && r.id > prev.id) { byName[r.name] = r }
            } else {
                byName[r.name] = r
            }
        }
        return Array(byName.values)
    }

    /// One state per head commit: failed (even while others run) > running > passed
    /// (skipped / neutral don't count against it) > all-cancelled > neutral.
    static func summarize(_ runs: [CheckRun]) -> CommitSummary {
        var s = CommitSummary(state: .neutral)
        var cancelled = 0
        let latest = latestRuns(runs)
        for r in latest {
            switch r.state {
            case .running: s.running += 1
            case .passed: s.passed += 1
            case .failed: s.failed += 1
            case .cancelled: s.other += 1; cancelled += 1
            case .skipped, .neutral: s.other += 1
            }
        }
        s.total = latest.count
        s.state = s.failed > 0 ? .failed : s.running > 0 ? .running : s.passed > 0 ? .passed : cancelled > 0 ? .cancelled : .neutral
        return s
    }

    /// Pill for this poll: red while a PR has a failed check; else the PRs with running
    /// checks; else green for `greenSeconds` after the last running PR passed; else idle.
    /// Events fire once per transition and only for PRs seen before (the first poll after
    /// launch is quiet).
    static func nextPill(_ prev: PillMemory, _ prs: [PRCI], now: Date) -> (pill: PillState, memory: PillMemory, events: [CIEvent]) {
        var events: [CIEvent] = []
        var states: [String: (sha: String, state: PRCIState)] = [:]
        for pr in prs {
            let s = pr.summary.state
            states[pr.key] = (pr.sha, s)
            guard let was = prev.states[pr.key] else { continue }
            let sameSha = was.sha == pr.sha
            if s == .failed, !(sameSha && was.state == .failed) {
                events.append(CIEvent(kind: .failed, key: pr.key, sha: pr.sha))
            } else if s == .passed, sameSha, was.state == .running {
                events.append(CIEvent(kind: .passed, key: pr.key, sha: pr.sha))
            }
        }
        let failing = prs.filter { $0.summary.state == .failed }.count
        let running = prs.filter { $0.summary.state == .running }.count
        var greenUntil = prev.greenUntil
        if failing > 0 || running > 0 { greenUntil = .distantPast }
        else if events.contains(where: { $0.kind == .passed }) { greenUntil = now.addingTimeInterval(greenSeconds) }
        let pill: PillState =
            failing > 0 ? PillState(color: .failed, count: failing)
            : running > 0 ? PillState(color: .running, count: running)
            : now < greenUntil ? PillState(color: .passed, count: 0)
            : PillState(color: .idle, count: 0)
        return (pill, PillMemory(states: states, greenUntil: greenUntil), events)
    }

    /// Wait before the next poll: 30 s only while a check runs, 5 min otherwise; island
    /// hidden 4x slower (as PollGate); doubled per failure, up to 30 min.
    static func pollInterval(anyRunning: Bool, hidden: Bool, failures: Int = 0) -> TimeInterval {
        let base = anyRunning ? fastInterval : slowInterval
        let slowed = hidden ? base * 4 : base
        return min(slowed * pow(2, Double(max(0, failures))), maxBackoff)
    }

    /// ".../actions/runs/123/job/456" → (123, 456).
    static func parseJobURL(_ url: String?) -> (runId: Int, jobId: Int)? {
        guard let url, let m = url.range(of: #"/actions/runs/(\d+)/job/(\d+)"#, options: .regularExpression) else { return nil }
        let parts = url[m].split(separator: "/")
        guard parts.count >= 5, let run = Int(parts[2]), let job = Int(parts[4]) else { return nil }
        return (run, job)
    }

    static func checkRunsPath(_ owner: String, _ repo: String, sha: String) -> String {
        "repos/\(owner)/\(repo)/commits/\(sha)/check-runs?per_page=100"
    }
    /// POST, on an explicit click only.
    static func rerunFailedPath(_ owner: String, _ repo: String, runId: Int) -> String {
        "repos/\(owner)/\(repo)/actions/runs/\(runId)/rerun-failed-jobs"
    }
    static func jobLogsPath(_ owner: String, _ repo: String, jobId: Int) -> String {
        "repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs"
    }

    /// The end of a failed job's log for the chat: ANSI colors and per-line timestamps
    /// removed, at most `maxLines` lines and `maxChars` characters (whole lines, from the
    /// end), with a first line saying it was cut.
    static func trimLogTail(_ log: String, maxLines: Int = 120, maxChars: Int = 6000) -> String {
        var lines = log.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> String in
                var l = line
                l = l.replacingOccurrences(of: #"^\x{FEFF}?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ?"#, with: "", options: .regularExpression)
                l = l.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
                while l.last == " " || l.last == "\t" { l.removeLast() }
                return l
            }
        while lines.last == "" { lines.removeLast() }
        var kept: [String] = []
        var chars = 0
        var i = lines.count - 1
        while i >= 0, kept.count < maxLines {
            let cost = lines[i].count + 1
            if chars + cost > maxChars {
                if kept.isEmpty { kept.insert(String(lines[i].suffix(maxChars)), at: 0) }  // one huge line
                break
            }
            kept.insert(lines[i], at: 0)
            chars += cost
            i -= 1
        }
        let cut = kept.count < lines.count
        return ((cut ? ["… (log cut, last lines only)"] : []) + kept).joined(separator: "\n")
    }

    // MARK: Poller and card helpers (the rest of #115)

    /// Your open PRs, newest first (REST search; `@me` is whoever the token or gh belongs to).
    static let maxPRs = 10
    static let myOpenPRsPath =
        "search/issues?q=is%3Apr+is%3Aopen+author%3A%40me+archived%3Afalse&sort=updated&order=desc&per_page=\(maxPRs)"
    static func pullPath(_ repo: String, number: Int) -> String { "repos/\(repo)/pulls/\(number)" }
    /// "Ask Mochi why" keeps this much of the failed job's log.
    static let logLines = 150
    static let logChars = 12_000

    /// The `check_runs` of GET …/check-runs. Entries without an id, name or status are skipped.
    static func parseCheckRuns(_ json: Any?) -> [CheckRun] {
        guard let list = (json as? [String: Any])?["check_runs"] as? [[String: Any]] else { return [] }
        return list.compactMap(CheckRun.parse)
    }

    private static func cardRank(_ s: CheckState) -> Int {
        switch s {
        case .failed: return 0
        case .running: return 1
        case .passed: return 2
        case .cancelled: return 3
        case .neutral: return 4
        case .skipped: return 5
        }
    }

    /// The runs shown on the card: newest per name, failed first, then running, then the rest, by name.
    static func cardRuns(_ runs: [CheckRun]) -> [CheckRun] {
        latestRuns(runs).sorted { a, b in
            let ra = cardRank(a.state), rb = cardRank(b.state)
            return ra != rb ? ra < rb : a.name < b.name
        }
    }

    /// "45s", "3m 07s", "1h 02m"; "" when unknown.
    static func formatDuration(_ seconds: Int?) -> String {
        guard let s = seconds, s >= 0 else { return "" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m " + String(format: "%02d", s % 60) + "s" }
        return "\(s / 3600)h " + String(format: "%02d", (s / 60) % 60) + "m"
    }

    /// The file attached to Mochi's chat by "Ask Mochi why": what failed, where, and the log's end.
    static func logAttachment(pr: String, title: String, job: String, sha: String, url: String, tail: String) -> String {
        var lines = ["CI check failed: \(job)",
                     "Pull request: \(pr)" + (title.isEmpty ? "" : " · \(title)"),
                     "Commit: \(sha.prefix(7))"]
        if !url.isEmpty { lines.append("Run: \(url)") }
        lines += ["", "Last lines of the job log:", tail]
        return lines.joined(separator: "\n")
    }
}
