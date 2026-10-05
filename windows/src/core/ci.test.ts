import { test } from "node:test";
import assert from "node:assert/strict";
import {
  checkState, summarize, latestRuns, durationSeconds, nextPill, emptyMemory, pollInterval,
  trimLogTail, parseJobUrl, rerunFailedPath, GREEN_MS, FAST_MS, SLOW_MS, MAX_BACKOFF_MS,
  parseCheckRuns, cardRuns, formatDuration, logAttachment, MY_OPEN_PRS_PATH, pullPath,
} from "./ci.ts";
import type { CheckRun, PrCI, CommitSummary } from "./ci.ts";

let n = 0;
const run = (name: string, status: string, conclusion: string | null = null, startedAt: string | null = null): CheckRun =>
  ({ id: ++n, name, status, conclusion, startedAt });
const done = (name: string, conclusion: string) => run(name, "completed", conclusion);
const sum = (...runs: CheckRun[]): CommitSummary => summarize(runs);
const pr = (key: string, sha: string, s: CommitSummary): PrCI => ({ key, sha, summary: s });

test("checkState maps every GitHub status / conclusion", () => {
  assert.equal(checkState({ status: "queued", conclusion: null }), "running");
  assert.equal(checkState({ status: "in_progress", conclusion: null }), "running");
  assert.equal(checkState({ status: "waiting", conclusion: null }), "running");
  assert.equal(checkState({ status: "completed", conclusion: "success" }), "passed");
  for (const c of ["failure", "timed_out", "startup_failure"]) assert.equal(checkState({ status: "completed", conclusion: c }), "failed");
  assert.equal(checkState({ status: "completed", conclusion: "cancelled" }), "cancelled");
  assert.equal(checkState({ status: "completed", conclusion: "skipped" }), "skipped");
  for (const c of ["neutral", "stale", "action_required", null]) assert.equal(checkState({ status: "completed", conclusion: c }), "neutral");
});

test("summarize: failed > running > passed > cancelled > neutral", () => {
  assert.equal(sum(done("a", "success"), done("b", "success")).state, "passed");
  assert.equal(sum(done("a", "success"), run("b", "in_progress")).state, "running");
  const red = sum(done("a", "failure"), run("b", "in_progress"), done("c", "success"));
  assert.equal(red.state, "failed", "red as soon as one fails, others still running");
  assert.deepEqual([red.running, red.passed, red.failed, red.total], [1, 1, 1, 3]);
  assert.equal(sum(done("a", "success"), done("b", "skipped"), done("c", "neutral")).state, "passed");
  assert.equal(sum(done("a", "skipped"), done("b", "neutral")).state, "neutral");
  assert.equal(sum(done("a", "cancelled"), done("b", "skipped")).state, "cancelled");
  assert.equal(sum(done("a", "cancelled"), done("b", "success")).state, "passed");
  assert.equal(sum().state, "neutral");
  assert.equal(sum().total, 0);
});

test("summarize keeps only the newest run of a re-run check", () => {
  const old = run("build", "completed", "failure", "2026-10-03T10:00:00Z");
  const again = run("build", "in_progress", null, "2026-10-03T10:05:00Z");
  assert.equal(latestRuns([again, old]).length, 1);
  assert.equal(summarize([old, again]).state, "running");
  const fixed = run("build", "completed", "success", "2026-10-03T10:05:00Z");
  assert.equal(summarize([fixed, old]).state, "passed");
});

test("durationSeconds", () => {
  const r = { ...run("a", "completed", "success"), startedAt: "2026-10-03T10:00:00Z", completedAt: "2026-10-03T10:01:12Z" };
  assert.equal(durationSeconds(r), 72);
  const live = { ...run("b", "in_progress"), startedAt: "2026-10-03T10:00:00Z" };
  assert.equal(durationSeconds(live, Date.parse("2026-10-03T10:00:30Z")), 30);
  assert.equal(durationSeconds(run("c", "queued")), null);
});

test("pill: counts running PRs, red on failure, brief green when all pass", () => {
  const running = sum(run("a", "in_progress"));
  const passed = sum(done("a", "success"));
  const failed = sum(done("a", "failure"));
  const t0 = 1_000_000;

  let r = nextPill(emptyMemory(), [pr("o/r#1", "s1", running), pr("o/r#2", "s2", running), pr("o/r#3", "s3", passed)], t0);
  assert.deepEqual(r.pill, { color: "running", count: 2 });
  assert.deepEqual(r.events, []);

  // #1 passes, #2 still runs: no green yet
  r = nextPill(r.memory, [pr("o/r#1", "s1", passed), pr("o/r#2", "s2", running), pr("o/r#3", "s3", passed)], t0 + 30_000);
  assert.deepEqual(r.pill, { color: "running", count: 1 });
  assert.deepEqual(r.events.map((e) => [e.kind, e.key]), [["passed", "o/r#1"]]);

  // #2 fails: red
  const m = r.memory;
  r = nextPill(m, [pr("o/r#1", "s1", passed), pr("o/r#2", "s2", failed), pr("o/r#3", "s3", passed)], t0 + 60_000);
  assert.deepEqual(r.pill, { color: "failed", count: 1 });
  assert.deepEqual(r.events.map((e) => [e.kind, e.key]), [["failed", "o/r#2"]]);
  // still red next poll, no second event
  r = nextPill(r.memory, [pr("o/r#1", "s1", passed), pr("o/r#2", "s2", failed), pr("o/r#3", "s3", passed)], t0 + 90_000);
  assert.deepEqual(r.pill, { color: "failed", count: 1 });
  assert.deepEqual(r.events, []);

  // push a fix: running, then all pass -> green for GREEN_MS, then idle
  r = nextPill(r.memory, [pr("o/r#2", "s2b", running)], t0 + 120_000);
  assert.equal(r.pill.color, "running");
  const tp = t0 + 150_000;
  r = nextPill(r.memory, [pr("o/r#2", "s2b", passed)], tp);
  assert.deepEqual(r.pill, { color: "passed", count: 0 });
  assert.deepEqual(r.events.map((e) => e.kind), ["passed"]);
  r = nextPill(r.memory, [pr("o/r#2", "s2b", passed)], tp + GREEN_MS - 1);
  assert.equal(r.pill.color, "passed");
  r = nextPill(r.memory, [pr("o/r#2", "s2b", passed)], tp + GREEN_MS);
  assert.equal(r.pill.color, "idle");
});

test("pill: first poll is quiet, a new commit failing fires again, closed PRs are forgotten", () => {
  const failed = sum(done("a", "failure"));
  const passed = sum(done("a", "success"));
  let r = nextPill(emptyMemory(), [pr("o/r#1", "s1", failed)], 0);
  assert.equal(r.pill.color, "failed");
  assert.deepEqual(r.events, [], "already red when Coucou started: no event");
  r = nextPill(r.memory, [pr("o/r#1", "s2", failed)], 1);
  assert.deepEqual(r.events.map((e) => e.kind), ["failed"], "new commit, red again");
  r = nextPill(r.memory, [], 2);
  assert.deepEqual(r.pill, { color: "idle", count: 0 });
  assert.deepEqual(r.memory.states, {});
  r = nextPill(r.memory, [pr("o/r#1", "s3", passed)], 3);
  assert.deepEqual(r.events, []);
});

test("pollInterval: 30 s only while running, slow otherwise, hidden 4x, backoff capped", () => {
  assert.equal(pollInterval({ anyRunning: true, hidden: false }), FAST_MS);
  assert.equal(pollInterval({ anyRunning: false, hidden: false }), SLOW_MS);
  assert.equal(pollInterval({ anyRunning: true, hidden: true }), FAST_MS * 4);
  assert.equal(pollInterval({ anyRunning: false, hidden: true }), SLOW_MS * 4);
  assert.equal(pollInterval({ anyRunning: true, hidden: false, failures: 2 }), FAST_MS * 4);
  assert.equal(pollInterval({ anyRunning: false, hidden: true, failures: 9 }), MAX_BACKOFF_MS);
  assert.equal(pollInterval({ anyRunning: true, hidden: false, failures: -3 }), FAST_MS);
});

test("trimLogTail: strips timestamps and colors, keeps the end, says when cut", () => {
  const log = [
    "2026-10-03T10:00:00.1234567Z ##[group]Run npm test",
    "2026-10-03T10:00:01.0000000Z \u001b[31mFAIL\u001b[0m src/a.test.ts",
    "2026-10-03T10:00:02Z   expected 1, got 2",
    "",
  ].join("\r\n");
  assert.equal(trimLogTail(log), "##[group]Run npm test\nFAIL src/a.test.ts\n  expected 1, got 2");

  const many = Array.from({ length: 500 }, (_, i) => `line ${i}`).join("\n");
  const out = trimLogTail(many, 50).split("\n");
  assert.equal(out[0], "… (log cut, last lines only)");
  assert.equal(out.length, 51);
  assert.equal(out[out.length - 1], "line 499");
  assert.equal(out[1], "line 450");

  const wide = trimLogTail(Array.from({ length: 100 }, () => "x".repeat(99)).join("\n"), 1000, 1000);
  assert.ok(wide.length <= 1000 + 40);
  assert.ok(wide.startsWith("… (log cut"));
  assert.equal(trimLogTail("y".repeat(50), 10, 20), "y".repeat(20), "one huge line: its last chars");
  assert.equal(trimLogTail(""), "");
});

test("parseJobUrl and API paths", () => {
  assert.deepEqual(parseJobUrl("https://github.com/o/r/actions/runs/123/job/456"), { runId: 123, jobId: 456 });
  assert.equal(parseJobUrl("https://github.com/o/r/runs/789"), null);
  assert.equal(parseJobUrl(null), null);
  assert.equal(rerunFailedPath("o", "r", 123), "repos/o/r/actions/runs/123/rerun-failed-jobs");
});

test("parseCheckRuns reads the REST payload and skips broken entries", () => {
  const runs = parseCheckRuns({ total_count: 3, check_runs: [
    { id: 7, name: "build", status: "completed", conclusion: "failure", started_at: "2026-10-01T10:00:00Z",
      completed_at: "2026-10-01T10:02:05Z", html_url: "https://github.com/o/r/actions/runs/11/job/22" },
    { id: 8, name: "lint", status: "in_progress", conclusion: null },
    { name: "no id", status: "queued" },
  ] });
  assert.equal(runs.length, 2);
  assert.deepEqual(runs[0], { id: 7, name: "build", status: "completed", conclusion: "failure",
    startedAt: "2026-10-01T10:00:00Z", completedAt: "2026-10-01T10:02:05Z",
    htmlUrl: "https://github.com/o/r/actions/runs/11/job/22" });
  assert.equal(runs[1].conclusion, null);
  assert.equal(runs[1].startedAt, null);
  assert.equal(durationSeconds(runs[0]), 125);
  assert.deepEqual(parseCheckRuns(null), []);
  assert.deepEqual(parseCheckRuns({ check_runs: "x" }), []);
});

test("cardRuns: newest per name, failed then running then passed, by name", () => {
  const order = cardRuns([
    done("b-pass", "success"), run("a-run", "queued"), done("z-fail", "failure"), done("a-fail", "timed_out"),
    done("skip", "skipped"), run("dup", "completed", "failure", "2026-10-01T10:00:00Z"),
    run("dup", "completed", "success", "2026-10-01T11:00:00Z"),
  ]).map((r) => r.name);
  assert.deepEqual(order, ["a-fail", "z-fail", "a-run", "b-pass", "dup", "skip"]);
});

test("formatDuration and the API paths", () => {
  assert.equal(formatDuration(null), "");
  assert.equal(formatDuration(45), "45s");
  assert.equal(formatDuration(187), "3m 07s");
  assert.equal(formatDuration(3720), "1h 02m");
  assert.ok(MY_OPEN_PRS_PATH.startsWith("search/issues?q=is%3Apr+is%3Aopen+author%3A%40me"));
  assert.equal(pullPath("o/r", 5), "repos/o/r/pulls/5");
});

test("logAttachment says what failed before the log tail", () => {
  const text = logAttachment({ pr: "o/r#5", title: "Fix it", job: "build", sha: "abcdef123456", url: "https://x/y", tail: "error: boom" });
  assert.equal(text, "CI check failed: build\nPull request: o/r#5 · Fix it\nCommit: abcdef1\nRun: https://x/y\n\nLast lines of the job log:\nerror: boom");
});
