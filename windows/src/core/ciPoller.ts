// CI pill (#115) on Windows / Linux: your open PRs' GitHub Actions checks. Port of
// CIPoller.swift. The page drives it so the tested logic in ci.ts decides the pill, the
// events and the interval (30 s while a check runs, 5 min otherwise, 4x slower with the
// island hidden, longer after errors); Rust (ci.rs) only makes the GitHub calls with the
// user's token or gh session, keeps ETags, and refuses anything else. No call while the
// pill is off or Coucou is paused. Logs and re-runs only follow a click.

import { Bridge, type DroppedFile } from "./bridge";
import { Sound } from "./sound";
import { State } from "./state";
import { dndActive } from "./dnd.ts";
import { parsePrSearch, type PrItem } from "./github-prs.ts";
import {
  cardRuns, checkRunsPath, checkState, emptyMemory, logAttachment, nextPill, parseCheckRuns, parseJobUrl,
  pollInterval, pullPath, summarize, trimLogTail, GREEN_MS, LOG_CHARS, LOG_LINES, MAX_PRS, MY_OPEN_PRS_PATH,
  SLOW_MS, type CIEvent, type CheckRun, type CommitSummary, type PillMemory, type PillState,
} from "./ci.ts";

export const CI_ID = "integration_ci";
/** While the pill is off: only look at the setting again, no network. */
const OFF_RECHECK_MS = 60_000;

/** One of your open PRs with the latest check runs of its head commit. */
export interface CIPr {
  key: string; // owner/name#123
  repo: string;
  number: number;
  title: string;
  url: string;
  sha: string;
  runs: CheckRun[]; // cardRuns order
  summary: CommitSummary;
}

let timer: ReturnType<typeof setTimeout> | null = null;
let memory: PillMemory = emptyMemory();
let failures = 0;
let polling = false;
let lastPrs: CIPr[] = [];
let reveal: () => void = () => {};
/** Head commits only change when the PR does: re-read the PR only when updated_at moves. */
const heads = new Map<string, { updatedAt: string; sha: string }>();

const enabled = () => State.settings.activeIntegrations.includes(CI_ID);

export function startCIPoller(onReveal: () => void) {
  reveal = onReveal;
  schedule(12_000);
}

/** Refresh button: poll now (nothing while the pill is off). */
export function refreshCI() {
  if (!enabled()) return;
  failures = 0;
  schedule(0);
}

function schedule(ms: number) {
  if (timer != null) clearTimeout(timer);
  timer = setTimeout(() => void tick(), ms);
}

async function tick() {
  timer = null;
  if (!enabled()) {
    // Off: forget, so turning it back on starts quiet (no event for what changed meanwhile).
    memory = emptyMemory();
    failures = 0;
    schedule(OFF_RECHECK_MS);
    return;
  }
  if (!State.paused) await poll();
  if (timer != null) return; // a click asked for a sooner poll meanwhile
  const anyRunning = lastPrs.some((p) => p.summary.state === "running");
  schedule(pollInterval({ anyRunning, hidden: State.mode === "hidden", failures }) || SLOW_MS);
}

const errText = (err: unknown) => String(err).replace(/^Error:\s*/, "");

async function headSha(item: PrItem): Promise<string | null> {
  const key = `${item.repo}#${item.number}`;
  const known = heads.get(key);
  if (known && known.updatedAt === item.updatedAt) return known.sha;
  const pr = (await Bridge.ciGet(pullPath(item.repo, item.number))) as { head?: { sha?: unknown } } | null;
  const sha = typeof pr?.head?.sha === "string" ? pr.head.sha : null;
  if (sha) heads.set(key, { updatedAt: item.updatedAt, sha });
  return sha;
}

async function fetchPrs(): Promise<CIPr[]> {
  const items = parsePrSearch(await Bridge.ciGet(MY_OPEN_PRS_PATH)).slice(0, MAX_PRS);
  const out: CIPr[] = [];
  for (const item of items) {
    const [owner, name] = item.repo.split("/");
    if (!owner || !name) continue;
    try {
      const sha = await headSha(item);
      if (!sha) continue;
      const runs = parseCheckRuns(await Bridge.ciGet(checkRunsPath(owner, name, sha)));
      out.push({
        key: `${item.repo}#${item.number}`, repo: item.repo, number: item.number, title: item.title, url: item.url,
        sha, runs: cardRuns(runs), summary: summarize(runs),
      });
    } catch {
      // One PR we can't read (no access to its checks) shouldn't hide the others.
    }
  }
  return out;
}

async function poll() {
  if (polling) return;
  polling = true;
  try {
    const prs = await fetchPrs();
    if (!enabled()) return;
    failures = 0;
    lastPrs = prs;
    const next = nextPill(memory, prs.map((p) => ({ key: p.key, sha: p.sha, summary: p.summary })), Date.now());
    memory = next.memory;
    const prev = State.integrations[CI_ID];
    State.integrations[CI_ID] = { data: { prs, pill: next.pill }, error: null, loaded: true, configured: prev?.configured ?? true };
    show(next.pill);
    announce(next.events);
    // Back to idle once the green moment is over (the next poll may be minutes away).
    if (next.pill.color === "passed") setTimeout(expireGreen, GREEN_MS + 200);
  } catch (err) {
    failures++;
    const prev = State.integrations[CI_ID];
    State.integrations[CI_ID] = {
      data: prev?.data ?? {}, error: errText(err), loaded: prev?.loaded ?? false, configured: prev?.configured ?? false,
    };
  } finally {
    polling = false;
    State.notify();
  }
}

function expireGreen() {
  if (!enabled()) return;
  const next = nextPill(memory, lastPrs.map((p) => ({ key: p.key, sha: p.sha, summary: p.summary })), Date.now());
  memory = next.memory;
  const info = State.integrations[CI_ID];
  if (info) info.data = { ...info.data, pill: next.pill };
  show(next.pill);
  State.notify();
}

/** The pill: red while a PR fails, working while checks run, green for a moment when all pass. */
function show(pill: PillState) {
  const task = State.tasks.find((t) => t.id === CI_ID);
  if (!task) return;
  switch (pill.color) {
    case "failed": {
      task.state = "error";
      const pr = lastPrs.find((p) => p.summary.state === "failed");
      const run = pr?.runs.find((r) => checkState(r) === "failed");
      task.steps = pill.count > 1 ? [`${pill.count} PRs failing`]
        : pr ? [`CI failed · ${pr.key}`, ...(run ? [run.name] : [])] : ["CI failed"];
      break;
    }
    case "running":
      task.state = "working";
      task.steps = [`${pill.count} running`];
      break;
    case "passed":
      task.state = "finished";
      task.steps = ["All checks passed"];
      break;
    default:
      task.state = "idle";
      task.steps = [];
      task.pillBadge = null;
  }
  task.stepIndex = 0;
}

/** A PR turned red, or the last running one passed: badge, sound and a peek, like the other pills. */
function announce(events: CIEvent[]) {
  if (!events.length) return;
  const failed = events.some((e) => e.kind === "failed");
  const task = State.tasks.find((t) => t.id === CI_ID);
  if (task && State.focusId !== CI_ID) task.pillBadge = failed ? "error" : "finished";
  if (dndActive(State.settings.dndUntil)) return;
  Sound.play(failed ? "error" : "finish");
  reveal();
}

// ── Card actions (explicit clicks only) ──────────────────────────────────────

/** "Ask Mochi why": the failed job's log tail as a text file, ready to attach to the chat. */
export async function ciLogFile(pr: CIPr, run: CheckRun): Promise<DroppedFile> {
  const job = parseJobUrl(run.htmlUrl);
  if (!job) throw new Error("This check isn't a GitHub Actions job, so there's no log to fetch.");
  const raw = await Bridge.ciJobLog(pr.repo, job.jobId);
  const tail = trimLogTail(raw, LOG_LINES, LOG_CHARS);
  const text = logAttachment({ pr: pr.key, title: pr.title, job: run.name, sha: pr.sha, url: run.htmlUrl ?? "", tail });
  return Bridge.ciSaveLog(`CI log - ${pr.repo.replace("/", " ")} ${pr.number} - ${run.name}`, text);
}

/** "Re-run failed jobs" for the workflow run this check belongs to; polls again shortly after. */
export async function ciRerunFailed(pr: CIPr, run: CheckRun): Promise<number> {
  const job = parseJobUrl(run.htmlUrl);
  if (!job) throw new Error("This check isn't a GitHub Actions job, so it can't be re-run from here.");
  await Bridge.ciRerunFailed(pr.repo, job.runId);
  failures = 0;
  schedule(6_000);
  return job.runId;
}
