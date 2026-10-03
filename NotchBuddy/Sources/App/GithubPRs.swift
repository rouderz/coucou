import Foundation

// GitHub pull requests (#113, step 1): the read-only list, plus the pure rules the later
// steps (review, merge, delete) will use. Mirrors windows/src/core/github-prs.ts.
// Nothing here writes to GitHub: reviews, merges and deletes are not wired.

enum PRChecksState: String, Sendable, Equatable { case success, failure, pending, none }
enum PRReviewState: String, Sendable, Equatable { case approved, changes, review, none }

struct PRItem: Identifiable, Equatable, Sendable {
    let repo: String          // owner/name
    let number: Int
    let title: String
    let url: String
    let author: String
    let draft: Bool
    let updatedAt: String
    var id: String { "\(repo)#\(number)" }
}

struct PRRow: Identifiable, Equatable, Sendable {
    let item: PRItem
    let ci: PRChecksState
    let review: PRReviewState
    var id: String { item.id }
}

struct PRLists: Equatable, Sendable {
    var toReview: [PRRow] = []
    var mine: [PRRow] = []
}

enum GitHubPRs {
    // MARK: Parsing

    /// `gh search prs --json number,title,url,repository,author,isDraft,updatedAt`, or REST
    /// `search/issues` (`items`). Entries without a number or repo are skipped.
    static func parseSearch(_ json: Any?) -> [PRItem] {
        let list: [[String: Any]]
        if let a = json as? [[String: Any]] { list = a }
        else if let o = json as? [String: Any], let a = o["items"] as? [[String: Any]] { list = a }
        else { return [] }
        return list.compactMap { o in
            guard let number = o["number"] as? Int, number > 0 else { return nil }
            let repoObj = o["repository"] as? [String: Any]
            var repo = (repoObj?["nameWithOwner"] as? String) ?? (repoObj?["full_name"] as? String) ?? ""
            if repo.isEmpty, let ru = o["repository_url"] as? String, let r = ru.range(of: "repos/") {
                repo = String(ru[r.upperBound...])
            }
            guard !repo.isEmpty else { return nil }
            let url = (o["url"] as? String).flatMap { $0.contains("/pull/") ? $0 : nil }
                ?? (o["html_url"] as? String) ?? (o["url"] as? String) ?? ""
            return PRItem(
                repo: repo, number: number,
                title: (o["title"] as? String) ?? "", url: url,
                author: ((o["author"] as? [String: Any])?["login"] as? String)
                     ?? ((o["user"] as? [String: Any])?["login"] as? String) ?? "",
                draft: (o["isDraft"] as? Bool) == true || (o["draft"] as? Bool) == true,
                updatedAt: (o["updatedAt"] as? String) ?? (o["updated_at"] as? String) ?? "")
        }
    }

    /// CI from check-runs and the combined status: failure wins, then anything running, then success.
    static func ciState(checkRuns: Any?, combined: Any?) -> PRChecksState {
        let runs = ((checkRuns as? [String: Any])?["check_runs"] as? [[String: Any]]) ?? []
        let statuses = ((combined as? [String: Any])?["statuses"] as? [[String: Any]]) ?? []
        if runs.isEmpty && statuses.isEmpty { return .none }
        let bad: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"]
        let good: Set<String> = ["success", "neutral", "skipped"]
        var pending = false
        for r in runs {
            if (r["status"] as? String) != "completed" { pending = true; continue }
            let c = (r["conclusion"] as? String) ?? ""
            if bad.contains(c) { return .failure }
            if !good.contains(c) { pending = true }
        }
        for s in statuses {
            let st = (s["state"] as? String) ?? ""
            if st == "failure" || st == "error" { return .failure }
            if st != "success" { pending = true }
        }
        return pending ? .pending : .success
    }

    static func ciSymbol(_ s: PRChecksState) -> String {
        switch s { case .success: "✓"; case .failure: "✗"; case .pending: "●"; case .none: "" }
    }

    /// Each reviewer's latest APPROVED / CHANGES_REQUESTED / DISMISSED counts; comments and
    /// pending drafts don't. "Changes requested" wins over approvals.
    static func reviewState(_ reviews: Any?, reviewRequested: Bool = false) -> PRReviewState {
        var latest: [String: String] = [:]
        for r in (reviews as? [[String: Any]]) ?? [] {
            let state = ((r["state"] as? String) ?? "").uppercased()
            guard let who = (r["user"] as? [String: Any])?["login"] as? String, !who.isEmpty,
                  ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(state) else { continue }
            latest[who] = state
        }
        let states = Set(latest.values)
        if states.contains("CHANGES_REQUESTED") { return .changes }
        if states.contains("APPROVED") { return .approved }
        return reviewRequested ? .review : .none
    }

    static func reviewLabel(_ s: PRReviewState) -> String {
        switch s {
        case .approved: L("Approved")
        case .changes:  L("Changes requested")
        case .review:   L("Review required")
        case .none:     ""
        }
    }

    /// "To review" hides drafts and your own PRs; "Mine" keeps drafts. Newest first.
    static func buildLists(requested: [PRItem], mine: [PRItem],
                           details: [String: (ci: PRChecksState, review: PRReviewState)] = [:]) -> PRLists {
        func row(_ p: PRItem) -> PRRow {
            let d = details[p.id]
            return PRRow(item: p, ci: d?.ci ?? .none, review: d?.review ?? .none)
        }
        let mineIDs = Set(mine.map(\.id))
        let recent: (PRRow, PRRow) -> Bool = { $0.item.updatedAt > $1.item.updatedAt }
        return PRLists(
            toReview: requested.filter { !$0.draft && !mineIDs.contains($0.id) }.map(row).sorted(by: recent),
            mine: mine.map(row).sorted(by: recent))
    }

    // MARK: Fetch (read-only, through the user's gh session)

    static let requestedArgs = ["search", "prs", "--review-requested=@me", "--state=open", "--limit", "30",
                                "--json", "number,title,url,repository,author,isDraft,updatedAt"]
    static let mineArgs = ["search", "prs", "--author=@me", "--state=open", "--limit", "30",
                           "--json", "number,title,url,repository,author,isDraft,updatedAt"]

    /// Both lists with CI and review state for "Mine" (one check-runs, one status and one reviews
    /// call per PR, so only your own are detailed). nil when gh is missing, signed out or fails.
    /// Blocking: call it off the main thread.
    static func fetch() -> PRLists? {
        guard let reqJSON = GitHubCLI.json(requestedArgs),
              let mineJSON = GitHubCLI.json(mineArgs) else { return nil }
        let requested = parseSearch(reqJSON), mine = parseSearch(mineJSON)
        var details: [String: (ci: PRChecksState, review: PRReviewState)] = [:]
        for p in mine.prefix(15) {
            guard let pr = GitHubCLI.api("repos/\(p.repo)/pulls/\(p.number)") as? [String: Any],
                  let sha = (pr["head"] as? [String: Any])?["sha"] as? String else { continue }
            let ci = ciState(checkRuns: GitHubCLI.api("repos/\(p.repo)/commits/\(sha)/check-runs?per_page=100"),
                             combined: GitHubCLI.api("repos/\(p.repo)/commits/\(sha)/status"))
            let requestedReviewers = (pr["requested_reviewers"] as? [Any])?.isEmpty == false
            let review = reviewState(GitHubCLI.api("repos/\(p.repo)/pulls/\(p.number)/reviews?per_page=100"),
                                     reviewRequested: requestedReviewers)
            details[p.id] = (ci, review)
        }
        return buildLists(requested: requested, mine: mine, details: details)
    }

    // MARK: Scopes

    /// Scopes from `gh auth status` ("- Token scopes: 'gist', 'repo'") or an `X-OAuth-Scopes` header.
    static func parseScopes(_ text: String) -> [String] {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            guard key.hasSuffix("token scopes") || key.hasSuffix("x-oauth-scopes") else { continue }
            return line[line.index(after: colon)...]
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`")) }
                .filter { !$0.isEmpty && $0 != "none" }
        }
        return []
    }

    private static let implied: [String: Set<String>] = [
        "repo": ["public_repo", "repo:status", "repo_deployment", "repo:invite", "security_events"],
        "admin:org": ["write:org", "read:org"],
        "write:org": ["read:org"],
    ]

    static func hasScope(_ granted: [String], _ needed: String) -> Bool {
        granted.contains(needed) || granted.contains { implied[$0]?.contains(needed) == true }
    }

    static func missingScopes(_ granted: [String], needed: [String]) -> [String] {
        needed.filter { !hasScope(granted, $0) }
    }

    /// The exact command to show for a missing scope.
    static func scopeHint(_ missing: [String]) -> String {
        missing.isEmpty ? "" : "gh auth refresh -s \(missing.joined(separator: ","))"
    }

    // MARK: Merge

    enum MergeMethod: String, Sendable { case merge, squash, rebase }

    /// The methods the repo allows (`allow_merge_commit` / `allow_squash_merge` / `allow_rebase_merge`).
    /// A payload without any of the flags counts as merge-commit only.
    static func allowedMergeMethods(_ repo: [String: Any]?) -> [MergeMethod] {
        let keys = ["allow_merge_commit", "allow_squash_merge", "allow_rebase_merge"]
        guard let repo, keys.contains(where: { repo[$0] != nil }) else { return [.merge] }
        var out: [MergeMethod] = []
        if (repo["allow_merge_commit"] as? Bool) == true { out.append(.merge) }
        if (repo["allow_squash_merge"] as? Bool) == true { out.append(.squash) }
        if (repo["allow_rebase_merge"] as? Bool) == true { out.append(.rebase) }
        return out
    }

    static func defaultMergeMethod(_ allowed: [MergeMethod], preferred: MergeMethod? = nil) -> MergeMethod? {
        if let preferred, allowed.contains(preferred) { return preferred }
        return allowed.first
    }

    /// Why Merge is disabled (nil when it can be clicked; the click is still required).
    static func mergeBlocker(draft: Bool, ci: PRChecksState, review: PRReviewState, allowed: [MergeMethod]) -> String? {
        if allowed.isEmpty { return L("No merge method is allowed on this repository") }
        if draft { return L("Draft pull request") }
        if ci == .failure { return L("Checks are failing") }
        if ci == .pending { return L("Checks are still running") }
        if review == .changes { return L("Changes were requested") }
        return nil
    }

    // MARK: Delete

    /// GitHub's rule: the full `owner/name`, exactly. Only surrounding whitespace is forgiven.
    static func deleteConfirmed(typed: String, owner: String, name: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == "\(owner)/\(name)"
    }

    // MARK: Review payload

    enum ReviewEvent: String, Sendable { case approve = "APPROVE", requestChanges = "REQUEST_CHANGES", comment = "COMMENT" }

    struct ReviewRequest: Equatable, Sendable {
        let path: String
        let event: ReviewEvent
        let body: String?
        /// The JSON that would be sent, for the confirmation sheet.
        var json: [String: String] {
            var d = ["event": event.rawValue]
            if let body { d["body"] = body }
            return d
        }
    }

    enum ReviewError: Error, Equatable, Sendable { case badRepo, badNumber, emptyComment }

    /// `POST repos/{o}/{r}/pulls/{n}/reviews`. Changes and comments need text; approving may not.
    /// Only builds the request: nothing is sent.
    static func buildReviewRequest(repo: String, number: Int, event: ReviewEvent, text: String) -> Result<ReviewRequest, ReviewError> {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(ok.contains) })
        else { return .failure(.badRepo) }
        guard number > 0 else { return .failure(.badNumber) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if event != .approve && body.isEmpty { return .failure(.emptyComment) }
        return .success(ReviewRequest(path: "repos/\(repo)/pulls/\(number)/reviews", event: event,
                                      body: body.isEmpty ? nil : body))
    }
}
