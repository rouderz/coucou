import AppKit

// CI pill (#115): GitHub Actions on your open PRs. Polls the head commit of each open PR you
// authored (30 s while a check runs, 5 min otherwise, 4x slower with the island hidden, nothing
// while the pill is off) and drives the pill from CICore (CIStatus.swift). Uses the GitHub
// connection like GithubPoller: the signed-in gh CLI, else the saved token. Fetching a job log
// and re-running failed jobs happen only on a click in the card.

/// One of your open PRs with the latest check runs of its head commit.
struct CIPullRequest: Identifiable, Equatable, Sendable {
    let repo: String       // owner/name
    let number: Int
    let title: String
    let url: String
    let sha: String
    let runs: [CheckRun]   // CICore.cardRuns order
    let summary: CommitSummary
    var id: String { "\(repo)#\(number)" }
}

// MARK: - GitHub calls (off the main thread)

enum CIGitHub {
    static let id = "integration_ci"

    enum Auth: Sendable, Equatable { case cli, token(String) }

    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    static var notConnected: String { L("Not connected to GitHub · sign in with gh or add a token in Settings") }

    /// The GitHub connection the GitHub card uses: gh while it's signed in, else the saved token.
    static func auth(cliSignedIn: Bool) -> Auth? {
        if cliSignedIn { return .cli }
        if let token = Secrets.store.get("github-token"), !token.isEmpty { return .token(token) }
        return nil
    }

    // Head commits only change when the PR does: re-read `pulls/{n}` only when its updated_at moves.
    private final class Memo: @unchecked Sendable {
        let lock = NSLock()
        var heads: [String: (updatedAt: String, sha: String)] = [:]
        var etags: [String: (etag: String, body: Data)] = [:]
    }
    private static let memo = Memo()

    /// Your open PRs (newest first, at most CICore.maxPRs) with their head commit's check runs.
    static func fetch(_ auth: Auth) async throws -> [CIPullRequest] {
        let search = try await get(CICore.myOpenPRsPath, auth, record: true)
        let items = GitHubPRs.parseSearch(search)
        var out: [CIPullRequest] = []
        for item in items.prefix(CICore.maxPRs) {
            let parts = item.repo.split(separator: "/").map(String.init)
            guard parts.count == 2 else { continue }
            // One PR we can't read (no access to its checks) shouldn't hide the others.
            guard let sha = try? await headSHA(item, auth),
                  let checks = try? await get(CICore.checkRunsPath(parts[0], parts[1], sha: sha), auth, record: false)
            else { continue }
            let runs = CICore.parseCheckRuns(checks)
            out.append(CIPullRequest(repo: item.repo, number: item.number, title: item.title, url: item.url,
                                     sha: sha, runs: CICore.cardRuns(runs), summary: CICore.summarize(runs)))
        }
        return out
    }

    private static func headSHA(_ item: PRItem, _ auth: Auth) async throws -> String? {
        let known = memo.lock.withLock { memo.heads[item.id] }
        if let known, known.updatedAt == item.updatedAt { return known.sha }
        let pr = try await get(CICore.pullPath(item.repo, number: item.number), auth, record: false)
        guard let sha = ((pr as? [String: Any])?["head"] as? [String: Any])?["sha"] as? String else { return nil }
        memo.lock.withLock { memo.heads[item.id] = (item.updatedAt, sha) }
        return sha
    }

    /// GET with ETags (gh's own cache, or ours for the token): unchanged data comes back as 304,
    /// which doesn't count against the rate limit.
    private static func get(_ path: String, _ auth: Auth, record: Bool) async throws -> Any {
        switch auth {
        case .cli:
            guard let json = GitHubCLI.apiCached(path) else {
                throw Failure(message: L("GitHub CLI request failed · check your connection"))
            }
            return json
        case .token(let token):
            let (data, code) = await request(path, token: token, method: "GET", record: record)
            guard code == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) else {
                throw Failure(message: code == 401 ? L("Token rejected · check it in Settings")
                                       : code == 0 ? L("Can't reach GitHub") : L("GitHub error \(code)"))
            }
            return json
        }
    }

    private static func request(_ path: String, token: String, method: String, record: Bool) async -> (Data?, Int) {
        guard let url = URL(string: "https://api.github.com/\(path)") else { return (nil, 0) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData  // we handle caching ourselves
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        var cached: (etag: String, body: Data)? = nil
        if method == "GET" { cached = memo.lock.withLock { memo.etags[path] } }
        if let cached { req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return (nil, 0) }
        if record { PollGate.shared.record(id, response) }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 304, let cached { return (cached.body, 200) }
        if code == 200, method == "GET", let etag = http?.value(forHTTPHeaderField: "ETag") {
            memo.lock.withLock { memo.etags[path] = (etag, data) }
        }
        return (data, code)
    }

    /// The end of a failed Actions job's log, cleaned for the chat. On a click only.
    static func jobLogTail(repo: String, jobId: Int, auth: Auth) async throws -> String {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw Failure(message: L("Couldn't fetch the job log")) }
        let path = CICore.jobLogsPath(parts[0], parts[1], jobId: jobId)
        let data: Data?
        switch auth {
        case .cli: data = GitHubCLI.raw(path)
        case .token(let token): data = await tokenLog(path, token: token)
        }
        guard let data, !data.isEmpty else { throw Failure(message: L("Couldn't fetch the job log")) }
        // Logs can be megabytes: only the end matters.
        let text = String(decoding: data.suffix(1_000_000), as: UTF8.self)
        return CICore.trimLogTail(text, maxLines: CICore.logLines, maxChars: CICore.logChars)
    }

    /// Stops URLSession from following the log's redirect, so the token isn't sent to the storage host.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private static func tokenLog(_ path: String, token: String) async -> Data? {
        guard let url = URL(string: "https://api.github.com/\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req, delegate: NoRedirect()),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 200 { return data }
        guard (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location) else { return nil }
        // A short-lived signed URL: no Authorization header.
        guard let (body, second) = try? await URLSession.shared.data(for: URLRequest(url: target, timeoutInterval: 30)),
              (second as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return body
    }

    /// POST …/rerun-failed-jobs. On an explicit click only.
    static func rerunFailed(repo: String, runId: Int, auth: Auth) async throws {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw Failure(message: L("Couldn't re-run the failed jobs")) }
        let path = CICore.rerunFailedPath(parts[0], parts[1], runId: runId)
        switch auth {
        case .cli:
            guard GitHubCLI.send("POST", path) else { throw Failure(message: L("Couldn't re-run the failed jobs")) }
        case .token(let token):
            let (_, code) = await request(path, token: token, method: "POST", record: false)
            guard (200..<300).contains(code) else {
                throw Failure(message: code == 403 ? L("GitHub refused the re-run (403) · the token needs the Actions permission")
                                                   : L("Couldn't re-run the failed jobs"))
            }
        }
    }

    /// The log, as a text file in the inbox folder (swept like dropped files), to attach to the chat.
    static func saveToInbox(_ text: String, name: String) throws -> URL {
        let inbox = HookServer.supportDir.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let base = GoogleText.safeFileName(name)
        var url = inbox.appendingPathComponent("\(base).txt")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = inbox.appendingPathComponent("\(base) (\(i)).txt")
            i += 1
        }
        try Data(text.utf8).write(to: url)
        return url
    }
}

// MARK: - Poller

@MainActor
final class CIPoller {
    static let shared = CIPoller()
    static let id = CIGitHub.id

    private var timer: Timer?
    private var memory = PillMemory()
    private var lastPoll: Date = .distantPast
    private var failures = 0
    private var polling = false

    private var enabled: Bool { AppState.shared.activeIntegrations.contains(Self.id) }

    private var auth: CIGitHub.Auth? {
        if case .cli = AppState.shared.githubConnection { return CIGitHub.auth(cliSignedIn: true) }
        return CIGitHub.auth(cliSignedIn: false)
    }

    func start() {
        // Ticks every 30 s; each tick decides whether a poll is due (CICore.pollInterval).
        timer = Timer.scheduledTimer(withTimeInterval: CICore.fastInterval, repeats: true) { _ in
            MainActor.assumeIsolated { CIPoller.shared.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { CIPoller.shared.tick() }
    }

    private func tick() {
        guard enabled else { forget(); return }
        let state = AppState.shared
        let anyRunning = state.ciPRs.contains { $0.summary.state == .running }
        let wait = CICore.pollInterval(anyRunning: anyRunning, hidden: state.mode == .hidden, failures: failures)
        guard Date().timeIntervalSince(lastPoll) >= wait - 1 else { return }
        // Screen locked / asleep, or backing off after an HTTP error.
        guard PollGate.shared.allow(Self.id, every: anyRunning ? CICore.fastInterval : CICore.slowInterval) else { return }
        poll()
    }

    /// Refresh button, island opened after a while, keys saved. Nothing while the pill is off.
    func pollNow() {
        guard enabled else { return }
        poll()
    }

    /// Pill switched off: no calls, and the next first poll is quiet again.
    private func forget() {
        memory = PillMemory()
        lastPoll = .distantPast
        failures = 0
    }

    private func poll() {
        guard !polling else { return }
        let state = AppState.shared
        guard let auth else {
            if case .checking = state.githubConnection { return }  // GithubPoller hasn't answered yet
            state.ciError = CIGitHub.notConnected
            state.ciLoaded = true
            return
        }
        polling = true
        lastPoll = Date()
        Task { @MainActor in
            defer { polling = false }
            do {
                let prs = try await Task.detached(priority: .utility) { try await CIGitHub.fetch(auth) }.value
                guard enabled else { return }
                failures = 0
                apply(prs)
            } catch {
                failures += 1
                state.ciError = error.localizedDescription
                state.ciLoaded = true
            }
        }
    }

    private static func keys(_ prs: [CIPullRequest]) -> [PRCI] {
        prs.map { PRCI(key: $0.id, sha: $0.sha, summary: $0.summary) }
    }

    private func apply(_ prs: [CIPullRequest]) {
        let state = AppState.shared
        if state.ciPRs != prs { state.ciPRs = prs }
        state.ciError = nil
        state.ciLoaded = true
        let next = CICore.nextPill(memory, Self.keys(prs), now: Date())
        memory = next.memory
        show(next.pill)
        announce(next.events)
        if next.pill.color == .passed {
            // Back to idle once the green moment is over (the next poll may be minutes away).
            DispatchQueue.main.asyncAfter(deadline: .now() + CICore.greenSeconds + 0.2) { CIPoller.shared.expireGreen() }
        }
    }

    private func expireGreen() {
        guard enabled else { return }
        let next = CICore.nextPill(memory, Self.keys(AppState.shared.ciPRs), now: Date())
        memory = next.memory
        show(next.pill)
    }

    /// The pill: red while a PR fails, working while checks run, green for a moment when all pass.
    private func show(_ pill: PillState) {
        let state = AppState.shared
        if state.ciPill != pill { state.ciPill = pill }
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.id }) else { return }
        var task = state.tasks[i]
        switch pill.color {
        case .failed:
            task.state = .error
            if pill.count > 1 {
                task.steps = [L("\(pill.count) PRs failing")]
            } else if let pr = state.ciPRs.first(where: { $0.summary.state == .failed }) {
                let failedRun = pr.runs.first(where: { $0.state == .failed })
                task.steps = [L("CI failed · \(pr.id)")] + (failedRun.map { [$0.name] } ?? [])
            } else {
                task.steps = [L("CI failed")]
            }
        case .running:
            task.state = .working
            task.steps = [L("\(pill.count) running")]
        case .passed:
            task.state = .finished
            task.steps = [L("All checks passed")]
        case .idle:
            task.state = .idle
            task.steps = []
            task.pillBadge = nil
        }
        task.stepIndex = 0
        if task != state.tasks[i] { state.tasks[i] = task }
    }

    /// A PR turned red, or the last running one passed: badge, sound and a peek, like the other pills.
    private func announce(_ events: [CIEvent]) {
        guard !events.isEmpty else { return }
        let state = AppState.shared
        let failed = events.contains { $0.kind == .failed }
        if state.focusId != Self.id, let i = state.tasks.firstIndex(where: { $0.id == Self.id }) {
            state.tasks[i].pillBadge = failed ? .error : .finished
        }
        guard !DoNotDisturb.shared.isActive else { return }
        SoundEngine.shared.play(failed ? "error" : "finish")
        NotificationCenter.default.post(name: .hookReveal, object: nil)
    }

    // MARK: Card actions (explicit clicks only)

    /// "Ask Mochi why": the failed job's log tail as a text file, attached to a new chat.
    func askWhy(_ pr: CIPullRequest, _ run: CheckRun) async throws {
        guard let job = CICore.parseJobURL(run.htmlURL) else {
            throw CIGitHub.Failure(message: L("This check isn't a GitHub Actions job, so there's no log to fetch."))
        }
        guard let auth else { throw CIGitHub.Failure(message: CIGitHub.notConnected) }
        let repo = pr.repo, jobId = job.jobId
        let tail = try await Task.detached(priority: .userInitiated) {
            try await CIGitHub.jobLogTail(repo: repo, jobId: jobId, auth: auth)
        }.value
        let text = CICore.logAttachment(pr: pr.id, title: pr.title, job: run.name, sha: pr.sha,
                                        url: run.htmlURL ?? "", tail: tail)
        let file = try CIGitHub.saveToInbox(text, name: "CI log - \(pr.repo) \(pr.number) - \(run.name)")
        GoogleAPI.attach(file, fresh: true)
    }

    /// "Re-run failed jobs" for the workflow run this check belongs to.
    func rerunFailed(_ pr: CIPullRequest, _ run: CheckRun) async throws {
        guard let job = CICore.parseJobURL(run.htmlURL) else {
            throw CIGitHub.Failure(message: L("This check isn't a GitHub Actions job, so it can't be re-run from here."))
        }
        guard let auth else { throw CIGitHub.Failure(message: CIGitHub.notConnected) }
        let repo = pr.repo, runId = job.runId
        try await Task.detached(priority: .userInitiated) {
            try await CIGitHub.rerunFailed(repo: repo, runId: runId, auth: auth)
        }.value
        // Pick up the new runs soon after GitHub queues them.
        PollGate.shared.manual(Self.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { CIPoller.shared.pollNow() }
    }
}
