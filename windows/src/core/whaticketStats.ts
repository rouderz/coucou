// WhaTicket stats (#whaticket-stats): the numbers drawn from the local log of tickets
// that arrived in the queue and the ones we accepted. The log itself is kept by
// src-tauri/src/whaticket.rs (whaticket-stats.json, a year, never uploaded); same rules
// as NotchBuddy/Sources/App/WhaTicketStats.swift.
//
// Pure functions only. Times are LOCAL (hour of day, days).
//
//  - "arrived": a ticket id seen in the queue for the first time.
//  - "accepted": it moved into my tickets — how = "click" (Coucou), "auto"
//    (auto-accept) or "web" (anywhere else); wait = seconds since it arrived.
//  - backlog = already waiting when we started watching (the tab had been closed):
//    counted as an arrival, but left out of the per-hour chart and of the waits.

import { csvCell } from "./timetrack.ts";

export interface StatEvent {
  id: string;
  kind: "arrived" | "accepted" | string;
  /** ms since epoch */
  at: number;
  /** local day it was logged, YYYY-MM-DD */
  day: string;
  queueId?: string;
  queue?: string;
  channel?: string;
  backlog?: boolean;
  how?: "click" | "auto" | "web" | string;
  wait?: number;
}

export interface QueueRow {
  /** "" = no queue */
  name: string;
  arrived: number;
  accepted: number;
  averageWait: number | null;
}

export interface Summary {
  arrived: number;
  /** Of which already waiting when we started watching. */
  backlog: number;
  accepted: number;
  click: number;
  auto: number;
  web: number;
  /** accepted / arrived (0…1), null with no arrivals. */
  rate: number | null;
  /** seconds */
  averageWait: number | null;
  medianWait: number | null;
  /** Busiest first. */
  queues: QueueRow[];
  /** 0…23, local. */
  hours: { arrived: number; accepted: number }[];
  days: { day: string; arrived: number; accepted: number }[];
}

export type Period = "today" | "week" | "month" | "custom";

export function dayKey(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function startOfDay(ms: number): Date {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d;
}

function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}

/** "YYYY-MM-DD" → local midnight of that day. */
export function parseDay(s: string): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s.trim());
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null;
}

/** [from, to) in ms. `custom` goes from the start of `from`'s day to the end of `to`'s day. */
export function range(period: Period, now: number, from?: string, to?: string): { from: number; to: number } {
  const today = startOfDay(now);
  const tomorrow = addDays(today, 1).getTime();
  switch (period) {
    case "today": return { from: today.getTime(), to: tomorrow };
    case "week": return { from: addDays(today, -6).getTime(), to: tomorrow };
    case "month": return { from: addDays(today, -29).getTime(), to: tomorrow };
    case "custom": {
      const a = parseDay(from ?? "") ?? today;
      const b = parseDay(to ?? "") ?? today;
      const [lo, hi] = a <= b ? [a, b] : [b, a];
      return { from: lo.getTime(), to: addDays(hi, 1).getTime() };
    }
  }
}

export function median(values: number[]): number | null {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : Math.round((s[mid - 1] + s[mid]) / 2);
}

export function average(values: number[]): number | null {
  return values.length ? Math.round(values.reduce((n, v) => n + v, 0) / values.length) : null;
}

export function queueName(e: StatEvent): string {
  return e.queue ?? e.queueId ?? "";
}

export function summary(events: StatEvent[], from: number, to: number): Summary {
  const s: Summary = {
    arrived: 0, backlog: 0, accepted: 0, click: 0, auto: 0, web: 0,
    rate: null, averageWait: null, medianWait: null, queues: [],
    hours: Array.from({ length: 24 }, () => ({ arrived: 0, accepted: 0 })),
    days: [],
  };
  const waits: number[] = [];
  const queues = new Map<string, { row: QueueRow; waits: number[] }>();
  const days = new Map<string, { arrived: number; accepted: number }>();
  for (const e of events) {
    if (!(e.at >= from && e.at < to)) continue;
    const name = queueName(e);
    const q = queues.get(name) ?? { row: { name, arrived: 0, accepted: 0, averageWait: null }, waits: [] };
    queues.set(name, q);
    const date = new Date(e.at);
    const day = dayKey(date);
    const d = days.get(day) ?? { arrived: 0, accepted: 0 };
    days.set(day, d);
    const hour = date.getHours();
    if (e.kind === "arrived") {
      s.arrived++;
      q.row.arrived++;
      d.arrived++;
      if (e.backlog) s.backlog++;
      else s.hours[hour].arrived++;
    } else if (e.kind === "accepted") {
      s.accepted++;
      q.row.accepted++;
      d.accepted++;
      s.hours[hour].accepted++;
      if (e.how === "click") s.click++;
      else if (e.how === "auto") s.auto++;
      else s.web++;
      if (typeof e.wait === "number") {
        waits.push(e.wait);
        q.waits.push(e.wait);
      }
    }
  }
  s.rate = s.arrived > 0 ? s.accepted / s.arrived : null;
  s.averageWait = average(waits);
  s.medianWait = median(waits);
  s.queues = [...queues.values()]
    .map(({ row, waits }) => ({ ...row, averageWait: average(waits) }))
    .sort((a, b) => b.arrived - a.arrived || b.accepted - a.accepted || a.name.localeCompare(b.name));
  // Every day of the range, empty ones included (at most ~13 months).
  for (let d = startOfDay(from), n = 0; d.getTime() < to && n < 400; d = addDays(d, 1), n++) {
    const key = dayKey(d);
    s.days.push({ day: key, ...(days.get(key) ?? { arrived: 0, accepted: 0 }) });
  }
  return s;
}

/** One row per event of the range: date, time, event, how, queue, wait seconds, ticket.
 *  `how` is "backlog" for a ticket already waiting when we started watching. */
export function toCsv(events: StatEvent[], from: number, to: number): string {
  const p = (n: number) => String(n).padStart(2, "0");
  const out = ["date,time,event,how,queue,wait_seconds,ticket"];
  for (const e of events) {
    if (!(e.at >= from && e.at < to)) continue;
    const d = new Date(e.at);
    const how = e.kind === "arrived" ? (e.backlog ? "backlog" : "") : (e.how ?? "");
    out.push([dayKey(d), `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`, e.kind, how,
      queueName(e), typeof e.wait === "number" ? String(e.wait) : "", e.id].map(csvCell).join(","));
  }
  return out.join("\n") + "\n";
}

/** "45 s", "3 min", "1 h 05 min", "—". */
export function duration(seconds: number | null | undefined): string {
  if (seconds == null) return "—";
  if (seconds < 60) return `${seconds} s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min`;
  return `${Math.floor(seconds / 3600)} h ${String(Math.floor((seconds % 3600) / 60)).padStart(2, "0")} min`;
}

/** The card's line: "Today · Arrived 23 · Accepted 18 (5 auto)". */
export function todayLine(t: { arrived?: unknown; accepted?: unknown; auto?: unknown } | null | undefined): string {
  const arrived = Number(t?.arrived ?? 0), accepted = Number(t?.accepted ?? 0), auto = Number(t?.auto ?? 0);
  return `Today · Arrived ${arrived} · Accepted ${accepted}${auto > 0 ? ` (${auto} auto)` : ""}`;
}
