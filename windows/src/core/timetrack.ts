// Time per Linear issue (#114): turns the session events the hook already sees
// (start / prompt / activity / stop / idle) into active time per issue per day.
//
// Pure functions only, no I/O: the app keeps the JSON text of the store in its
// app-data folder and hands it to parseStore / serializeStore. Nothing here is
// ever uploaded. Days are LOCAL days.
//
// Rules
//  - A session is "working" from a start / prompt / activity event until its
//    next event. A stop or idle event closes the span at its own time.
//  - A gap longer than the idle threshold between two events is NOT counted
//    (the user walked away, or the session was abandoned); the next event
//    simply starts a new span. The exception is a gap that ends with a stop:
//    that turn really ran (a long build, a long answer), so it is counted.
//  - A span still open at the end counts only up to `now`, and only while
//    `now` is within the idle threshold of the last event.
//  - A span belongs to the issue linked to the session (the earlier event's
//    link, else the later one's). Without an issue it goes to "repo @ branch".
//  - Spans of different sessions on the same issue are merged (union), so two
//    parallel sessions never count the same minute twice.
//  - Spans crossing local midnight are split between the two days.

export type TimeEventKind = "start" | "prompt" | "activity" | "stop" | "idle";

export interface TimeIssue {
  identifier: string;
  title: string;
}

export interface TimeEvent {
  session: string;
  kind: TimeEventKind;
  /** ms since epoch */
  at: number;
  issue?: TimeIssue | null;
  repo?: string;
  branch?: string;
}

export interface TimeOptions {
  /** Gaps longer than this are not counted. Default 10 minutes. */
  idleMs?: number;
  /** Counts a span that is still open, up to now. */
  now?: number;
}

export interface TimeSpan {
  key: string;
  start: number;
  end: number;
  issue?: TimeIssue;
  repo?: string;
  branch?: string;
}

/** Time spent on one issue (or one repo/branch) on one day. */
export interface DayRow {
  /** YYYY-MM-DD, local */
  day: string;
  /** "SHO-475", or "repo @ branch" */
  key: string;
  issue?: TimeIssue;
  repo?: string;
  branch?: string;
  ms: number;
}

/** A manual +/- on a day and key (also an entry for work outside Claude Code). */
export interface Adjustment {
  day: string;
  key: string;
  deltaMs: number;
  /** Shown when the key has no tracked time that day. */
  title?: string;
}

export const DEFAULT_IDLE_MS = 10 * 60_000;
const MINUTE = 60_000;

// MARK: - Spans

function spanKey(e: { issue?: TimeIssue | null; repo?: string; branch?: string }): string {
  if (e.issue?.identifier) return e.issue.identifier;
  const repo = e.repo?.trim() || "(no repo)";
  const branch = e.branch?.trim();
  return branch ? `${repo} @ ${branch}` : repo;
}

/** The working spans of every session, before merging. */
export function spansFromEvents(events: TimeEvent[], opts: TimeOptions = {}): TimeSpan[] {
  const idle = opts.idleMs ?? DEFAULT_IDLE_MS;
  const bySession = new Map<string, TimeEvent[]>();
  for (const e of events) {
    if (!Number.isFinite(e.at)) continue;
    const list = bySession.get(e.session) ?? [];
    list.push(e);
    bySession.set(e.session, list);
  }
  const spans: TimeSpan[] = [];
  const push = (from: TimeEvent, to: number, next?: TimeEvent) => {
    if (to <= from.at) return;
    const src = from.issue ? from : next?.issue ? next : from;
    spans.push({
      key: spanKey(src),
      start: from.at,
      end: to,
      issue: src.issue ?? undefined,
      repo: src.repo ?? from.repo ?? next?.repo,
      branch: src.branch ?? from.branch ?? next?.branch,
    });
  };
  for (const list of bySession.values()) {
    const sorted = list.map((e, i) => ({ e, i })).sort((a, b) => a.e.at - b.e.at || a.i - b.i).map((x) => x.e);
    let open: TimeEvent | null = null; // last event of the current working span
    for (const e of sorted) {
      if (open && (e.at - open.at <= idle || e.kind === "stop")) push(open, e.at, e);
      open = e.kind === "stop" || e.kind === "idle" ? null : e;
    }
    if (open && opts.now !== undefined && opts.now - open.at <= idle) push(open, opts.now);
  }
  return spans;
}

// MARK: - Days

const pad = (n: number) => String(n).padStart(2, "0");

/** YYYY-MM-DD of a timestamp, in local time. */
export function dayKey(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function nextMidnight(ms: number): number {
  const d = new Date(ms);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
}

/** Union of overlapping or touching spans of one key, split at local midnight, summed per day. */
export function aggregate(events: TimeEvent[], opts: TimeOptions = {}): DayRow[] {
  const byKey = new Map<string, TimeSpan[]>();
  for (const s of spansFromEvents(events, opts)) {
    const list = byKey.get(s.key) ?? [];
    list.push(s);
    byKey.set(s.key, list);
  }
  const rows = new Map<string, DayRow>();
  for (const [key, list] of byKey) {
    list.sort((a, b) => a.start - b.start);
    const merged: { start: number; end: number }[] = [];
    for (const s of list) {
      const last = merged[merged.length - 1];
      if (last && s.start <= last.end) last.end = Math.max(last.end, s.end);
      else merged.push({ start: s.start, end: s.end });
    }
    // Latest known title / repo / branch for the key.
    const meta = list.reduce((a, b) => (b.start >= a.start ? b : a));
    for (const m of merged) {
      let from = m.start;
      while (from < m.end) {
        const to = Math.min(m.end, nextMidnight(from));
        const day = dayKey(from);
        const id = `${day}\u0000${key}`;
        const row = rows.get(id) ?? { day, key, issue: meta.issue, repo: meta.repo, branch: meta.branch, ms: 0 };
        row.ms += to - from;
        rows.set(id, row);
        from = to;
      }
    }
  }
  return sortRows([...rows.values()]);
}

function sortRows(rows: DayRow[]): DayRow[] {
  return rows.sort((a, b) => a.day.localeCompare(b.day) || b.ms - a.ms || a.key.localeCompare(b.key));
}

/** Manual edits on top of the tracked time. Never below zero; empty rows disappear. */
export function applyAdjustments(rows: DayRow[], adjustments: Adjustment[]): DayRow[] {
  const map = new Map<string, DayRow>();
  for (const r of rows) map.set(`${r.day}\u0000${r.key}`, { ...r });
  for (const a of adjustments) {
    const id = `${a.day}\u0000${a.key}`;
    const row = map.get(id) ?? {
      day: a.day,
      key: a.key,
      issue: /^[A-Z][A-Z0-9]+-\d+$/.test(a.key) ? { identifier: a.key, title: a.title ?? "" } : undefined,
      ms: 0,
    };
    row.ms = Math.max(0, row.ms + a.deltaMs);
    map.set(id, row);
  }
  return sortRows([...map.values()].filter((r) => r.ms > 0));
}

// MARK: - Periods

export interface PeriodDay {
  day: string;
  rows: DayRow[];
  ms: number;
  /** One line for the timesheet: "SHO-475: PDP redesign; SHO-480: Cart bug". */
  description: string;
}

/** The first or second half of the month a date is in, as inclusive YYYY-MM-DD bounds. */
export function halfMonth(date: Date): { from: string; to: string } {
  const y = date.getFullYear(), m = date.getMonth();
  if (date.getDate() <= 15) return { from: `${y}-${pad(m + 1)}-01`, to: `${y}-${pad(m + 1)}-15` };
  const last = new Date(y, m + 1, 0).getDate();
  return { from: `${y}-${pad(m + 1)}-16`, to: `${y}-${pad(m + 1)}-${pad(last)}` };
}

export function describeRows(rows: DayRow[]): string {
  return [...rows]
    .sort((a, b) => b.ms - a.ms)
    .map((r) => (r.issue ? (r.issue.title ? `${r.issue.identifier}: ${r.issue.title}` : r.issue.identifier) : r.key))
    .join("; ");
}

/** Rows from `from` to `to` (inclusive), grouped by day, days without time left out. */
export function groupPeriod(rows: DayRow[], from: string, to: string): PeriodDay[] {
  const days = new Map<string, DayRow[]>();
  for (const r of rows) {
    if (r.day < from || r.day > to || r.ms <= 0) continue;
    days.set(r.day, [...(days.get(r.day) ?? []), r]);
  }
  return [...days.keys()].sort().map((day) => {
    const list = days.get(day)!.sort((a, b) => b.ms - a.ms || a.key.localeCompare(b.key));
    return { day, rows: list, ms: list.reduce((n, r) => n + r.ms, 0), description: describeRows(list) };
  });
}

// MARK: - Export (rows only; nothing is written anywhere)

/** Rounds to a step in minutes (0 = no rounding). */
export function roundMs(ms: number, stepMinutes = 0): number {
  if (stepMinutes <= 0) return ms;
  const step = stepMinutes * MINUTE;
  return Math.round(ms / step) * step;
}

export function formatHours(ms: number): string {
  return (ms / 3_600_000).toFixed(2);
}

/** "1h 05m" */
export function formatDuration(ms: number): string {
  const m = Math.round(ms / MINUTE);
  return `${Math.floor(m / 60)}h ${pad(m % 60)}m`;
}

export interface ExportOptions {
  roundMinutes?: number;
}

/** Plain text, one block per day. */
export function toText(days: PeriodDay[], opts: ExportOptions = {}): string {
  const lines: string[] = [];
  let total = 0;
  for (const d of days) {
    const ms = d.rows.reduce((n, r) => n + roundMs(r.ms, opts.roundMinutes), 0);
    total += ms;
    lines.push(`${d.day}  ${formatHours(ms)} h  ${d.description}`);
  }
  if (days.length) lines.push(`Total  ${formatHours(total)} h`);
  return lines.join("\n");
}

/** A CSV cell (RFC 4180). Titles come from Linear, so a leading = + - @ is defused for spreadsheets. */
export function csvCell(value: string | number): string {
  let s = String(value);
  if (/^[=+\-@\t\r]/.test(s) && typeof value === "string") s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

/**
 * CSV. "issue" = one row per day and issue (Date, Issue, Title, Repo, Branch, Hours);
 * "day" = one row per day (Date, Hours, Description).
 */
export function toCsv(days: PeriodDay[], mode: "issue" | "day" = "issue", opts: ExportOptions = {}): string {
  const out: string[] = [];
  if (mode === "day") {
    out.push("Date,Hours,Description");
    for (const d of days) {
      const ms = d.rows.reduce((n, r) => n + roundMs(r.ms, opts.roundMinutes), 0);
      out.push([d.day, formatHours(ms), d.description].map(csvCell).join(","));
    }
  } else {
    out.push("Date,Issue,Title,Repo,Branch,Hours");
    for (const d of days) {
      for (const r of d.rows) {
        out.push(
          [d.day, r.issue?.identifier ?? "", r.issue?.title ?? "", r.repo ?? "", r.branch ?? "", formatHours(roundMs(r.ms, opts.roundMinutes))]
            .map(csvCell)
            .join(","),
        );
      }
    }
  }
  return out.join("\n") + "\n";
}

// MARK: - Local store

export interface TimeStore {
  version: 1;
  events: TimeEvent[];
  adjustments: Adjustment[];
}

export const EMPTY_STORE: TimeStore = { version: 1, events: [], adjustments: [] };

const KINDS: TimeEventKind[] = ["start", "prompt", "activity", "stop", "idle"];

function cleanEvent(raw: unknown): TimeEvent | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.session !== "string" || !r.session || typeof r.at !== "number" || !Number.isFinite(r.at)) return null;
  if (!KINDS.includes(r.kind as TimeEventKind)) return null;
  const issue = r.issue as Record<string, unknown> | null | undefined;
  const e: TimeEvent = { session: r.session, kind: r.kind as TimeEventKind, at: r.at };
  if (issue && typeof issue.identifier === "string") {
    e.issue = { identifier: issue.identifier, title: typeof issue.title === "string" ? issue.title : "" };
  }
  if (typeof r.repo === "string") e.repo = r.repo;
  if (typeof r.branch === "string") e.branch = r.branch;
  return e;
}

/** Reads the file's text. Anything unreadable gives an empty store, bad entries are dropped. */
export function parseStore(text: string | null | undefined): TimeStore {
  if (!text) return { ...EMPTY_STORE, events: [], adjustments: [] };
  try {
    const j = JSON.parse(text) as Record<string, unknown>;
    const events = (Array.isArray(j.events) ? j.events : []).map(cleanEvent).filter((e): e is TimeEvent => e !== null);
    const adjustments = (Array.isArray(j.adjustments) ? j.adjustments : []).filter(
      (a): a is Adjustment =>
        !!a && typeof a.day === "string" && typeof a.key === "string" && typeof a.deltaMs === "number" && Number.isFinite(a.deltaMs),
    );
    return { version: 1, events, adjustments };
  } catch {
    return { ...EMPTY_STORE, events: [], adjustments: [] };
  }
}

export function serializeStore(store: TimeStore): string {
  return JSON.stringify(store);
}

export const KEEP_DAYS = 180;
const ACTIVITY_MERGE_MS = 30_000;

/**
 * Adds an event (returns a new store). A run of "activity" events of a session less than
 * 30 s apart is kept as one event moved forward, so tool-heavy sessions don't grow the
 * file while the covered time stays the same. Events older than KEEP_DAYS are dropped.
 */
export function recordEvent(store: TimeStore, event: TimeEvent, now = event.at): TimeStore {
  const cutoff = now - KEEP_DAYS * 86_400_000;
  const events = store.events.filter((e) => e.at >= cutoff);
  if (event.kind === "activity") {
    for (let i = events.length - 1; i >= 0; i--) {
      if (events[i].session !== event.session) continue;
      const prev = events[i];
      if (prev.kind === "activity" && event.at >= prev.at && event.at - prev.at < ACTIVITY_MERGE_MS
        && spanKey(prev) === spanKey(event)) {
        events[i] = { ...event };
        return { ...store, events };
      }
      break;
    }
  }
  events.push(event);
  return { ...store, events };
}

/** Adds a manual edit; edits of the same day and key are summed. */
export function addAdjustment(store: TimeStore, adj: Adjustment): TimeStore {
  const list = store.adjustments.map((a) => ({ ...a }));
  const same = list.find((a) => a.day === adj.day && a.key === adj.key);
  if (same) {
    same.deltaMs += adj.deltaMs;
    if (adj.title) same.title = adj.title;
  } else list.push({ ...adj });
  return { ...store, adjustments: list.filter((a) => a.deltaMs !== 0) };
}

/** Everything the views and exports need, from the store. */
export function rowsFromStore(store: TimeStore, opts: TimeOptions = {}): DayRow[] {
  return applyAdjustments(aggregate(store.events, opts), store.adjustments);
}
