// CI pill (#115): GitHub Actions status of your open PRs. Pure logic only (check-run
// aggregation, pill state, polling interval, failed-log tail); the poller and the card
// call these. Mirrored in NotchBuddy/Sources/App/CIStatus.swift, keep both in step.

export type CheckState = "running" | "passed" | "failed" | "cancelled" | "skipped" | "neutral";
/** A PR (or commit) as a whole. "neutral" also covers "only skipped checks". */
export type PrState = "running" | "passed" | "failed" | "cancelled" | "neutral";

/** The fields we use from GET /repos/{o}/{r}/commits/{sha}/check-runs. */
export interface CheckRun {
  id: number;
  name: string;
  status: string;            // queued | in_progress | completed | waiting | pending | requested
  conclusion: string | null; // success | failure | neutral | cancelled | skipped | timed_out | action_required | stale | startup_failure
  startedAt?: string | null;
  completedAt?: string | null;
  htmlUrl?: string | null;
}

export function checkState(run: Pick<CheckRun, "status" | "conclusion">): CheckState {
  if (run.status !== "completed") return "running";
  switch (run.conclusion) {
    case "success": return "passed";
    case "failure": case "timed_out": case "startup_failure": return "failed";
    case "cancelled": return "cancelled";
    case "skipped": return "skipped";
    // neutral, stale, action_required (waits for a person, not a red build), unknown
    default: return "neutral";
  }
}

/** Seconds a run took (to now while it is still running); null when unknown. */
export function durationSeconds(run: CheckRun, now = Date.now()): number | null {
  if (!run.startedAt) return null;
  const start = Date.parse(run.startedAt);
  if (Number.isNaN(start)) return null;
  const end = run.completedAt ? Date.parse(run.completedAt) : now;
  if (Number.isNaN(end)) return null;
  return Math.max(0, Math.round((end - start) / 1000));
}

const startOf = (r: CheckRun) => (r.startedAt ? Date.parse(r.startedAt) || 0 : 0);

/** Re-runs list a check twice: keep the newest run of each name. */
export function latestRuns(runs: CheckRun[]): CheckRun[] {
  const byName = new Map<string, CheckRun>();
  for (const r of runs) {
    const prev = byName.get(r.name);
    if (!prev || startOf(r) > startOf(prev) || (startOf(r) === startOf(prev) && r.id > prev.id)) byName.set(r.name, r);
  }
  return [...byName.values()];
}

export interface CommitSummary {
  state: PrState;
  running: number;
  passed: number;
  failed: number;
  other: number; // cancelled + skipped + neutral
  total: number;
}

/**
 * One state per head commit. A red check wins even while others still run (the pill
 * turns red as soon as one fails); then running; then passed if anything passed
 * (skipped / neutral don't count against it); all-cancelled is "cancelled";
 * nothing but skipped / neutral, or no checks at all, is "neutral".
 */
export function summarize(runs: CheckRun[]): CommitSummary {
  const latest = latestRuns(runs);
  let running = 0, passed = 0, failed = 0, cancelled = 0, other = 0;
  for (const r of latest) {
    const s = checkState(r);
    if (s === "running") running++;
    else if (s === "passed") passed++;
    else if (s === "failed") failed++;
    else { other++; if (s === "cancelled") cancelled++; }
  }
  const state: PrState =
    failed > 0 ? "failed" :
    running > 0 ? "running" :
    passed > 0 ? "passed" :
    cancelled > 0 ? "cancelled" : "neutral";
  return { state, running, passed, failed, other, total: latest.length };
}

/** A PR (or watched branch) with the summary of its head commit's checks. */
export interface PrCI {
  key: string;     // "owner/repo#123", or "owner/repo@branch" for a watched branch
  sha: string;     // head commit the summary is about
  summary: CommitSummary;
}

export type PillColor = "idle" | "running" | "failed" | "passed";
export interface PillState {
  color: PillColor;
  count: number;   // failing PRs when red, PRs with running checks when running
}
export interface PillMemory {
  states: Record<string, { sha: string; state: PrState }>;
  greenUntil: number; // ms; 0 = no green
}
export type CIEvent = { kind: "failed" | "passed"; key: string; sha: string };

export const GREEN_MS = 8_000;
export const emptyMemory = (): PillMemory => ({ states: {}, greenUntil: 0 });

/**
 * Pill for this poll. Red while any PR has a failed check; else the number of PRs
 * with running checks; else green for GREEN_MS after the last running PR passed; else
 * idle. Events fire once per transition and only for PRs seen before: "passed" when a
 * PR that was running on the same commit passes, "failed" when it turns red. The first
 * poll after launch is quiet.
 */
export function nextPill(prev: PillMemory, prs: PrCI[], now: number): { pill: PillState; memory: PillMemory; events: CIEvent[] } {
  const events: CIEvent[] = [];
  const states: PillMemory["states"] = {};
  for (const pr of prs) {
    const was = prev.states[pr.key];
    const s = pr.summary.state;
    states[pr.key] = { sha: pr.sha, state: s };
    if (!was) continue;
    const sameSha = was.sha === pr.sha;
    if (s === "failed" && !(sameSha && was.state === "failed")) events.push({ kind: "failed", key: pr.key, sha: pr.sha });
    else if (s === "passed" && sameSha && was.state === "running") events.push({ kind: "passed", key: pr.key, sha: pr.sha });
  }
  const failing = prs.filter((p) => p.summary.state === "failed").length;
  const running = prs.filter((p) => p.summary.state === "running").length;
  let greenUntil = prev.greenUntil;
  if (failing > 0 || running > 0) greenUntil = 0;
  else if (events.some((e) => e.kind === "passed")) greenUntil = now + GREEN_MS;
  let pill: PillState;
  if (failing > 0) pill = { color: "failed", count: failing };
  else if (running > 0) pill = { color: "running", count: running };
  else if (now < greenUntil) pill = { color: "passed", count: 0 };
  else pill = { color: "idle", count: 0 };
  return { pill, memory: { states, greenUntil }, events };
}

export const FAST_MS = 30_000;
export const SLOW_MS = 300_000;
export const MAX_BACKOFF_MS = 30 * 60_000;

/**
 * Wait before the next poll. 30 s only while a check runs; 5 min otherwise. Island
 * hidden: 4x slower (as PollGate does). Errors: doubled per failure, up to 30 min.
 */
export function pollInterval(o: { anyRunning: boolean; hidden: boolean; failures?: number }): number {
  const base = o.anyRunning ? FAST_MS : SLOW_MS;
  const slowed = o.hidden ? base * 4 : base;
  const n = Math.max(0, o.failures ?? 0);
  return Math.min(slowed * 2 ** n, MAX_BACKOFF_MS);
}

/** "…/actions/runs/123/job/456" -> { runId, jobId } (an Actions check run links there). */
export function parseJobUrl(url: string | null | undefined): { runId: number; jobId: number } | null {
  const m = /\/actions\/runs\/(\d+)\/job\/(\d+)/.exec(url ?? "");
  return m ? { runId: Number(m[1]), jobId: Number(m[2]) } : null;
}

export const checkRunsPath = (owner: string, repo: string, sha: string) =>
  `repos/${owner}/${repo}/commits/${sha}/check-runs?per_page=100`;
/** POST, on an explicit click only. */
export const rerunFailedPath = (owner: string, repo: string, runId: number) =>
  `repos/${owner}/${repo}/actions/runs/${runId}/rerun-failed-jobs`;
export const jobLogsPath = (owner: string, repo: string, jobId: number) =>
  `repos/${owner}/${repo}/actions/jobs/${jobId}/logs`;

// eslint-disable-next-line no-control-regex
const ANSI = /\u001b\[[0-9;?]*[ -/]*[@-~]/g;
const STAMP = /^﻿?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z ?/;

/**
 * The end of a failed job's log, ready to attach to a chat: ANSI colors and the
 * per-line timestamps removed, at most `maxLines` lines and `maxChars` characters
 * (whole lines, from the end), with a first line saying it was cut.
 */
export function trimLogTail(log: string, maxLines = 120, maxChars = 6000): string {
  const lines = log.replace(/\r\n?/g, "\n").split("\n").map((l) => l.replace(STAMP, "").replace(ANSI, "").trimEnd());
  while (lines.length && lines[lines.length - 1] === "") lines.pop();
  const kept: string[] = [];
  let chars = 0;
  for (let i = lines.length - 1; i >= 0 && kept.length < maxLines; i--) {
    const cost = lines[i].length + 1;
    if (chars + cost > maxChars) {
      if (kept.length === 0) kept.unshift(lines[i].slice(-maxChars)); // one huge line
      break;
    }
    kept.unshift(lines[i]);
    chars += cost;
  }
  const cut = kept.length < lines.length;
  return (cut ? ["… (log cut, last lines only)"] : []).concat(kept).join("\n");
}
