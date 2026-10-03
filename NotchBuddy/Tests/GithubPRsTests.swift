import XCTest
@testable import Coucou

/// The PR list parsers and the pure rules for later steps (#113). Mirrors windows/src/core/github-prs.test.ts.
final class GithubPRsTests: XCTestCase {
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private func pr(_ n: Int, _ repo: String, draft: Bool = false) -> PRItem {
        PRItem(repo: repo, number: n, title: "PR \(n)", url: "https://github.com/\(repo)/pull/\(n)",
               author: "ada", draft: draft, updatedAt: "2026-10-0\(n)T10:00:00Z")
    }

    func testParseGhSearch() throws {
        let items = GitHubPRs.parseSearch(try json("""
        [{"number":1,"title":"A","url":"https://github.com/o/a/pull/1","repository":{"nameWithOwner":"o/a"},
          "author":{"login":"ada"},"isDraft":false,"updatedAt":"2026-10-01T10:00:00Z"},
         {"number":2,"title":"B","url":"https://github.com/o/b/pull/2","repository":{"nameWithOwner":"o/b"},
          "author":{"login":"ada"},"isDraft":true,"updatedAt":"2026-10-02T10:00:00Z"},
         {"title":"no number"}]
        """))
        XCTAssertEqual(items.map(\.id), ["o/a#1", "o/b#2"])
        XCTAssertEqual(items.map(\.draft), [false, true])
        XCTAssertEqual(items[0].author, "ada")
    }

    func testParseRestSearch() throws {
        let items = GitHubPRs.parseSearch(try json("""
        {"items":[{"number":7,"title":"x","html_url":"https://github.com/o/a/pull/7",
          "repository_url":"https://api.github.com/repos/o/a","user":{"login":"bob"},"draft":true,
          "updated_at":"2026-10-01T00:00:00Z"}]}
        """))
        XCTAssertEqual(items.first?.repo, "o/a")
        XCTAssertEqual(items.first?.url, "https://github.com/o/a/pull/7")
        XCTAssertEqual(items.first?.author, "bob")
        XCTAssertEqual(items.first?.draft, true)
        XCTAssertTrue(GitHubPRs.parseSearch(nil).isEmpty)
        XCTAssertTrue(GitHubPRs.parseSearch(try json(#"{"message":"Bad credentials"}"#)).isEmpty)
    }

    func testCIState() throws {
        func ci(_ runs: String, _ statuses: String = "[]") throws -> PRCIState {
            GitHubPRs.ciState(checkRuns: try json(#"{"check_runs":\#(runs)}"#),
                              combined: try json(#"{"statuses":\#(statuses)}"#))
        }
        XCTAssertEqual(try ci(#"[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]"#), .success)
        XCTAssertEqual(try ci(#"[{"status":"completed","conclusion":"success"},{"status":"in_progress"}]"#), .pending)
        XCTAssertEqual(try ci(#"[{"status":"in_progress"},{"status":"completed","conclusion":"failure"}]"#), .failure)
        XCTAssertEqual(try ci("[]", #"[{"state":"success"},{"state":"pending"}]"#), .pending)
        XCTAssertEqual(try ci(#"[{"status":"completed","conclusion":"success"}]"#, #"[{"state":"error"}]"#), .failure)
        XCTAssertEqual(try ci("[]"), .none)
        XCTAssertEqual(GitHubPRs.ciState(checkRuns: nil, combined: nil), .none)
        XCTAssertEqual([PRCIState.success, .failure, .pending].map(GitHubPRs.ciSymbol), ["✓", "✗", "●"])
    }

    func testReviewState() throws {
        func rs(_ text: String, requested: Bool = false) throws -> PRReviewState {
            GitHubPRs.reviewState(try json(text), reviewRequested: requested)
        }
        XCTAssertEqual(try rs(#"[{"user":{"login":"a"},"state":"APPROVED"}]"#), .approved)
        XCTAssertEqual(try rs(#"[{"user":{"login":"a"},"state":"CHANGES_REQUESTED"},{"user":{"login":"a"},"state":"APPROVED"}]"#), .approved)
        XCTAssertEqual(try rs(#"[{"user":{"login":"a"},"state":"APPROVED"},{"user":{"login":"b"},"state":"CHANGES_REQUESTED"}]"#), .changes)
        XCTAssertEqual(try rs(#"[{"user":{"login":"a"},"state":"CHANGES_REQUESTED"},{"user":{"login":"a"},"state":"DISMISSED"}]"#), .none)
        XCTAssertEqual(try rs(#"[{"user":{"login":"a"},"state":"COMMENTED"}]"#, requested: true), .review)
        XCTAssertEqual(try rs("[]"), .none)
    }

    func testLists() {
        let lists = GitHubPRs.buildLists(
            requested: [pr(1, "o/a"), pr(3, "o/a"), pr(2, "o/b", draft: true), pr(4, "o/c")],
            mine: [pr(4, "o/c"), pr(2, "o/b", draft: true)],
            details: ["o/c#4": (.failure, .changes), "o/a#3": (.success, .none)])
        XCTAssertEqual(lists.toReview.map(\.item.number), [3, 1], "no drafts, none of mine, newest first")
        XCTAssertEqual(lists.toReview.first?.ci, .success)
        XCTAssertEqual(lists.mine.map(\.item.number), [4, 2])
        XCTAssertEqual(lists.mine.first?.ci, .failure)
        XCTAssertEqual(lists.mine.first?.review, .changes)
    }

    func testScopes() {
        let status = """
        github.com
          ✓ Logged in to github.com account ada (keyring)
          - Active account: true
          - Token scopes: 'gist', 'read:org', 'repo'
        """
        XCTAssertEqual(GitHubPRs.parseScopes(status), ["gist", "read:org", "repo"])
        XCTAssertEqual(GitHubPRs.parseScopes("X-OAuth-Scopes: repo, delete_repo"), ["repo", "delete_repo"])
        XCTAssertEqual(GitHubPRs.parseScopes("X-OAuth-Scopes: \nX-Other: 1"), [])
        XCTAssertEqual(GitHubPRs.parseScopes("nothing"), [])
        XCTAssertEqual(GitHubPRs.missingScopes(["repo"], needed: ["repo", "delete_repo"]), ["delete_repo"])
        XCTAssertEqual(GitHubPRs.scopeHint(["delete_repo"]), "gh auth refresh -s delete_repo")
        XCTAssertEqual(GitHubPRs.scopeHint(["delete_repo", "workflow"]), "gh auth refresh -s delete_repo,workflow")
        XCTAssertEqual(GitHubPRs.scopeHint([]), "")
        XCTAssertTrue(GitHubPRs.hasScope(["admin:org"], "read:org"))
        XCTAssertFalse(GitHubPRs.hasScope(["repo"], "delete_repo"))
    }

    func testMergeMethods() {
        XCTAssertEqual(GitHubPRs.allowedMergeMethods(["allow_merge_commit": true, "allow_squash_merge": true, "allow_rebase_merge": false]), [.merge, .squash])
        XCTAssertEqual(GitHubPRs.allowedMergeMethods(["allow_merge_commit": false, "allow_squash_merge": true, "allow_rebase_merge": true]), [.squash, .rebase])
        XCTAssertEqual(GitHubPRs.allowedMergeMethods(["allow_merge_commit": false, "allow_squash_merge": false, "allow_rebase_merge": false]), [])
        XCTAssertEqual(GitHubPRs.allowedMergeMethods(nil), [.merge])
        XCTAssertEqual(GitHubPRs.defaultMergeMethod([.squash, .rebase], preferred: .merge), .squash)
        XCTAssertEqual(GitHubPRs.defaultMergeMethod([.merge, .squash], preferred: .squash), .squash)
        XCTAssertNil(GitHubPRs.defaultMergeMethod([]))
    }

    func testMergeBlockers() {
        func b(draft: Bool = false, ci: PRCIState = .success, review: PRReviewState = .approved,
               allowed: [GitHubPRs.MergeMethod] = [.merge]) -> String? {
            GitHubPRs.mergeBlocker(draft: draft, ci: ci, review: review, allowed: allowed)
        }
        XCTAssertNil(b())
        XCTAssertNil(b(ci: .none))
        XCTAssertNotNil(b(ci: .pending))
        XCTAssertNotNil(b(ci: .failure))
        XCTAssertNotNil(b(draft: true))
        XCTAssertNotNil(b(review: .changes))
        XCTAssertNotNil(b(allowed: []))
    }

    func testDeleteConfirmation() {
        XCTAssertTrue(GitHubPRs.deleteConfirmed(typed: "rouderz/coucou", owner: "rouderz", name: "coucou"))
        XCTAssertTrue(GitHubPRs.deleteConfirmed(typed: " rouderz/coucou\n", owner: "rouderz", name: "coucou"))
        XCTAssertFalse(GitHubPRs.deleteConfirmed(typed: "coucou", owner: "rouderz", name: "coucou"))
        XCTAssertFalse(GitHubPRs.deleteConfirmed(typed: "Rouderz/Coucou", owner: "rouderz", name: "coucou"))
        XCTAssertFalse(GitHubPRs.deleteConfirmed(typed: "", owner: "rouderz", name: "coucou"))
    }

    func testReviewPayload() throws {
        let path = "repos/o/r/pulls/5/reviews"
        let approve = try GitHubPRs.buildReviewRequest(repo: "o/r", number: 5, event: .approve, text: "  ").get()
        XCTAssertEqual(approve.path, path)
        XCTAssertEqual(approve.json, ["event": "APPROVE"])
        let changes = try GitHubPRs.buildReviewRequest(repo: "o/r", number: 5, event: .requestChanges, text: " Fix the race ").get()
        XCTAssertEqual(changes.json, ["event": "REQUEST_CHANGES", "body": "Fix the race"])
        XCTAssertEqual(try GitHubPRs.buildReviewRequest(repo: "o/r", number: 5, event: .comment, text: "hi").get().json["event"], "COMMENT")
        XCTAssertEqual(GitHubPRs.buildReviewRequest(repo: "o/r", number: 5, event: .comment, text: "").mapError { $0 }, .failure(.emptyComment))
        XCTAssertEqual(GitHubPRs.buildReviewRequest(repo: "bad", number: 5, event: .comment, text: "x").mapError { $0 }, .failure(.badRepo))
        XCTAssertEqual(GitHubPRs.buildReviewRequest(repo: "o/r", number: 0, event: .comment, text: "x").mapError { $0 }, .failure(.badNumber))
    }
}
