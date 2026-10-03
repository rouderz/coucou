import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parsePrSearch, ciState, reviewState, buildLists, parseScopes, missingScopes, scopeHint, hasScope,
  allowedMergeMethods, defaultMergeMethod, mergeBlocker, deleteConfirmed, buildReviewRequest, CI_SYMBOL,
} from "./github-prs.ts";

const ghPr = (n: number, repo: string, extra: object = {}) => ({
  number: n, title: `PR ${n}`, url: `https://github.com/${repo}/pull/${n}`,
  repository: { nameWithOwner: repo, name: repo.split("/")[1] }, author: { login: "ada" },
  isDraft: false, updatedAt: `2026-10-0${n}T10:00:00Z`, ...extra,
});

test("search: gh search prs JSON", () => {
  const items = parsePrSearch([ghPr(1, "o/a"), ghPr(2, "o/b", { isDraft: true }), { title: "no number" }, ghPr(3, "")]);
  assert.deepEqual(items.map((p) => [p.repo, p.number, p.draft, p.author]), [["o/a", 1, false, "ada"], ["o/b", 2, true, "ada"]]);
  assert.equal(items[0].url, "https://github.com/o/a/pull/1");
});

test("search: REST search/issues items", () => {
  const items = parsePrSearch({ items: [{
    number: 7, title: "x", html_url: "https://github.com/o/a/pull/7", repository_url: "https://api.github.com/repos/o/a",
    user: { login: "bob" }, draft: true, updated_at: "2026-10-01T00:00:00Z",
  }] });
  assert.deepEqual(items[0], { repo: "o/a", number: 7, title: "x", url: "https://github.com/o/a/pull/7", author: "bob", draft: true, updatedAt: "2026-10-01T00:00:00Z" });
  assert.deepEqual(parsePrSearch(null), []);
  assert.deepEqual(parsePrSearch({ message: "Bad credentials" }), []);
});

test("ci: failure beats pending beats success", () => {
  const run = (status: string, conclusion: string | null) => ({ status, conclusion });
  assert.equal(ciState({ check_runs: [run("completed", "success"), run("completed", "skipped")] }, { statuses: [] }), "success");
  assert.equal(ciState({ check_runs: [run("completed", "success"), run("in_progress", null)] }, {}), "pending");
  assert.equal(ciState({ check_runs: [run("in_progress", null), run("completed", "failure")] }, {}), "failure");
  assert.equal(ciState({ check_runs: [run("completed", "timed_out")] }, {}), "failure");
  assert.equal(ciState({ check_runs: [] }, { statuses: [{ state: "success" }, { state: "pending" }] }), "pending");
  assert.equal(ciState({ check_runs: [run("completed", "success")] }, { statuses: [{ state: "error" }] }), "failure");
  assert.equal(ciState({ check_runs: [] }, { statuses: [] }), "none");
  assert.equal(ciState(undefined, undefined), "none");
  assert.deepEqual([CI_SYMBOL.success, CI_SYMBOL.failure, CI_SYMBOL.pending], ["✓", "✗", "●"]);
});

test("review: latest decision per reviewer", () => {
  const r = (who: string, state: string) => ({ user: { login: who }, state });
  assert.equal(reviewState([r("a", "APPROVED")]), "approved");
  assert.equal(reviewState([r("a", "CHANGES_REQUESTED"), r("a", "APPROVED")]), "approved", "a later approval replaces");
  assert.equal(reviewState([r("a", "APPROVED"), r("b", "CHANGES_REQUESTED")]), "changes");
  assert.equal(reviewState([r("a", "CHANGES_REQUESTED"), r("a", "DISMISSED")]), "none", "dismissed clears it");
  assert.equal(reviewState([r("a", "COMMENTED"), r("a", "PENDING")], true), "review");
  assert.equal(reviewState([]), "none");
  assert.equal(reviewState("nope"), "none");
});

test("lists: To review hides drafts and my own PRs; both newest first", () => {
  const req = parsePrSearch([ghPr(1, "o/a"), ghPr(3, "o/a"), ghPr(2, "o/b", { isDraft: true }), ghPr(4, "o/c")]);
  const mine = parsePrSearch([ghPr(4, "o/c"), ghPr(2, "o/b", { isDraft: true })]);
  const lists = buildLists(req, mine, { "o/c#4": { ci: "failure", review: "changes" }, "o/a#3": { ci: "success" } });
  assert.deepEqual(lists.toReview.map((p) => p.number), [3, 1]);
  assert.equal(lists.toReview[0].ci, "success");
  assert.equal(lists.toReview[1].ci, "none");
  assert.deepEqual(lists.mine.map((p) => [p.number, p.ci, p.review]), [[4, "failure", "changes"], [2, "none", "none"]]);
});

test("scopes: gh auth status and the X-OAuth-Scopes header", () => {
  const status = `github.com\n  ✓ Logged in to github.com account ada (keyring)\n  - Active account: true\n  - Token scopes: 'gist', 'read:org', 'repo'\n`;
  assert.deepEqual(parseScopes(status), ["gist", "read:org", "repo"]);
  assert.deepEqual(parseScopes("X-OAuth-Scopes: repo, delete_repo"), ["repo", "delete_repo"]);
  assert.deepEqual(parseScopes("X-OAuth-Scopes: \nX-Other: 1"), []);
  assert.deepEqual(parseScopes("nothing here"), []);
});

test("scopes: missing ones and the exact refresh hint", () => {
  const granted = ["repo", "read:org"];
  assert.deepEqual(missingScopes(granted, ["repo", "delete_repo"]), ["delete_repo"]);
  assert.equal(scopeHint(["delete_repo"]), "gh auth refresh -s delete_repo");
  assert.equal(scopeHint(["delete_repo", "workflow"]), "gh auth refresh -s delete_repo,workflow");
  assert.equal(scopeHint([]), "");
  assert.ok(hasScope(["admin:org"], "read:org"));
  assert.ok(hasScope(["repo"], "public_repo"));
  assert.ok(!hasScope(["repo"], "delete_repo"), "repo does not include delete_repo");
});

test("merge: methods follow the repo settings", () => {
  assert.deepEqual(allowedMergeMethods({ allow_merge_commit: true, allow_squash_merge: true, allow_rebase_merge: false }), ["merge", "squash"]);
  assert.deepEqual(allowedMergeMethods({ allow_merge_commit: false, allow_squash_merge: true, allow_rebase_merge: true }), ["squash", "rebase"]);
  assert.deepEqual(allowedMergeMethods({ allow_merge_commit: false, allow_squash_merge: false, allow_rebase_merge: false }), []);
  assert.deepEqual(allowedMergeMethods(null), ["merge"]);
  assert.equal(defaultMergeMethod(["squash", "rebase"], "merge"), "squash", "never a forbidden method");
  assert.equal(defaultMergeMethod(["merge", "squash"], "squash"), "squash");
  assert.equal(defaultMergeMethod([]), null);
});

test("merge: blockers", () => {
  const ok = { draft: false, ci: "success" as const, review: "approved" as const };
  assert.equal(mergeBlocker(ok, ["merge"]), null);
  assert.equal(mergeBlocker({ ...ok, ci: "none" }, ["merge"]), null);
  assert.equal(mergeBlocker({ ...ok, ci: "pending" }, ["merge"]), "Checks are still running");
  assert.equal(mergeBlocker({ ...ok, ci: "failure" }, ["merge"]), "Checks are failing");
  assert.equal(mergeBlocker({ ...ok, draft: true }, ["merge"]), "Draft pull request");
  assert.equal(mergeBlocker({ ...ok, review: "changes" }, ["merge"]), "Changes were requested");
  assert.equal(mergeBlocker(ok, []), "No merge method is allowed on this repository");
});

test("delete: the full owner/name, exactly", () => {
  assert.ok(deleteConfirmed("rouderz/coucou", "rouderz", "coucou"));
  assert.ok(deleteConfirmed("  rouderz/coucou\n", "rouderz", "coucou"));
  assert.ok(!deleteConfirmed("coucou", "rouderz", "coucou"));
  assert.ok(!deleteConfirmed("Rouderz/Coucou", "rouderz", "coucou"));
  assert.ok(!deleteConfirmed("rouderz/coucou2", "rouderz", "coucou"));
  assert.ok(!deleteConfirmed("", "rouderz", "coucou"));
});

test("review payload: APPROVE / REQUEST_CHANGES / COMMENT", () => {
  const path = "repos/o/r/pulls/5/reviews";
  assert.deepEqual(buildReviewRequest("o/r", 5, "APPROVE", "  "), { method: "POST", path, body: { event: "APPROVE" } });
  assert.deepEqual(buildReviewRequest("o/r", 5, "APPROVE", " LGTM "), { method: "POST", path, body: { event: "APPROVE", body: "LGTM" } });
  assert.deepEqual(buildReviewRequest("o/r", 5, "REQUEST_CHANGES", "Fix the race"), { method: "POST", path, body: { event: "REQUEST_CHANGES", body: "Fix the race" } });
  assert.deepEqual(buildReviewRequest("o/r", 5, "REQUEST_CHANGES", " "), { error: "Write a comment first" });
  assert.deepEqual(buildReviewRequest("o/r", 5, "COMMENT", ""), { error: "Write a comment first" });
  assert.deepEqual(buildReviewRequest("bad", 5, "COMMENT", "x"), { error: "Repository must look like owner/name" });
  assert.deepEqual(buildReviewRequest("o/r", 0, "COMMENT", "x"), { error: "Invalid pull request number" });
});
