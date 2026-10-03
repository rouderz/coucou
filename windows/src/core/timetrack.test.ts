import { test } from "node:test";
import assert from "node:assert/strict";
import {
  addAdjustment, aggregate, applyAdjustments, csvCell, dayKey, groupPeriod, halfMonth, parseStore,
  recordEvent, rowsFromStore, serializeStore, toCsv, toText, EMPTY_STORE, KEEP_DAYS,
  type TimeEvent, type TimeIssue,
} from "./timetrack.ts";

const MIN = 60_000;
const t = (h: number, m = 0, day = 16) => new Date(2026, 8, day, h, m).getTime();
const SHO475: TimeIssue = { identifier: "SHO-475", title: "PDP redesign" };
const SHO480: TimeIssue = { identifier: "SHO-480", title: "Cart bug" };

const ev = (session: string, kind: TimeEvent["kind"], at: number, issue: TimeIssue | null = SHO475, extra: Partial<TimeEvent> = {}): TimeEvent =>
  ({ session, kind, at, issue, repo: "shop", branch: "feat/sho-475", ...extra });

const minutes = (rows: { ms: number }[]) => rows.map((r) => r.ms / MIN);

test("a simple turn counts from prompt to stop", () => {
  const rows = aggregate([ev("a", "start", t(9)), ev("a", "prompt", t(9, 1)), ev("a", "stop", t(9, 31))]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].key, "SHO-475");
  assert.equal(rows[0].day, "2026-09-16");
  assert.equal(rows[0].ms, 31 * MIN); // start (9:00) to stop (9:31)
});

test("time after a stop is not counted until the next prompt", () => {
  const rows = aggregate([
    ev("a", "prompt", t(9)), ev("a", "stop", t(9, 10)),
    ev("a", "prompt", t(9, 15)), ev("a", "stop", t(9, 20)),
  ]);
  assert.deepEqual(minutes(rows), [15]);
});

test("a gap over the idle threshold is not counted at all", () => {
  const events = [ev("a", "prompt", t(9)), ev("a", "activity", t(9, 5)), ev("a", "activity", t(9, 40)), ev("a", "stop", t(9, 42))];
  assert.deepEqual(minutes(aggregate(events, { idleMs: 10 * MIN })), [5 + 2]);
  // A bigger threshold counts the gap.
  assert.deepEqual(minutes(aggregate(events, { idleMs: 60 * MIN })), [42]);
});

test("a long turn that ends with a stop is counted, one that never ended is not", () => {
  const long = [ev("a", "prompt", t(9)), ev("a", "stop", t(9, 45))];
  assert.deepEqual(minutes(aggregate(long, { idleMs: 10 * MIN })), [45]);
  const abandoned = [ev("a", "prompt", t(9)), ev("a", "prompt", t(9, 45)), ev("a", "stop", t(9, 50))];
  assert.deepEqual(minutes(aggregate(abandoned, { idleMs: 10 * MIN })), [5]);
});

test("a gap exactly at the threshold is counted", () => {
  const events = [ev("a", "prompt", t(9)), ev("a", "stop", t(9, 10))];
  assert.deepEqual(minutes(aggregate(events, { idleMs: 10 * MIN })), [10]);
});

test("an idle event closes the span where it happens", () => {
  const events = [ev("a", "prompt", t(9)), ev("a", "idle", t(9, 8)), ev("a", "prompt", t(10)), ev("a", "stop", t(10, 3))];
  assert.deepEqual(minutes(aggregate(events)), [11]);
});

test("a span left open counts up to now while recent, and not after the idle threshold", () => {
  const events = [ev("a", "prompt", t(9)), ev("a", "activity", t(9, 4))];
  assert.deepEqual(minutes(aggregate(events, { now: t(9, 9) })), [9]);
  assert.deepEqual(minutes(aggregate(events, { now: t(9, 30) })), [4]);
  assert.deepEqual(minutes(aggregate(events)), [4]);
});

test("overlapping sessions on the same issue are merged, not added", () => {
  const rows = aggregate([
    ev("a", "prompt", t(9)), ev("a", "stop", t(9, 30)),
    ev("b", "prompt", t(9, 20)), ev("b", "stop", t(9, 50)),
  ]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].ms, 50 * MIN); // 9:00-9:50, not 60
});

test("a session fully inside another adds nothing; touching sessions add up", () => {
  const inside = aggregate([
    ev("a", "prompt", t(9)), ev("a", "stop", t(10)),
    ev("b", "prompt", t(9, 10)), ev("b", "stop", t(9, 20)),
  ]);
  assert.deepEqual(minutes(inside), [60]);
  const touching = aggregate([
    ev("a", "prompt", t(9)), ev("a", "stop", t(9, 10)),
    ev("b", "prompt", t(9, 10)), ev("b", "stop", t(9, 25)),
  ]);
  assert.deepEqual(minutes(touching), [25]);
});

test("three overlapping sessions chain into one block", () => {
  const rows = aggregate([
    ev("a", "prompt", t(9)), ev("a", "stop", t(9, 10)),
    ev("b", "prompt", t(9, 8)), ev("b", "stop", t(9, 20)),
    ev("c", "prompt", t(9, 19)), ev("c", "stop", t(9, 30)),
  ]);
  assert.deepEqual(minutes(rows), [30]);
});

test("parallel sessions on different issues each keep their time", () => {
  const rows = aggregate([
    ev("a", "prompt", t(9)), ev("a", "stop", t(9, 30)),
    ev("b", "prompt", t(9, 10), SHO480), ev("b", "stop", t(9, 40), SHO480),
  ]);
  assert.deepEqual(rows.map((r) => [r.key, r.ms / MIN]), [["SHO-475", 30], ["SHO-480", 30]]);
});

test("sessions without an issue are grouped by repo and branch", () => {
  const none = (s: string, k: TimeEvent["kind"], at: number, repo: string, branch?: string) =>
    ev(s, k, at, null, { repo, branch });
  const rows = aggregate([
    none("a", "prompt", t(9), "coucou", "main"), none("a", "stop", t(9, 20), "coucou", "main"),
    none("b", "prompt", t(10), "coucou", "main"), none("b", "stop", t(10, 5), "coucou", "main"),
    none("c", "prompt", t(11), "coucou", "fix-x"), none("c", "stop", t(11, 7), "coucou", "fix-x"),
    none("d", "prompt", t(12), "notes", undefined), none("d", "stop", t(12, 2), "notes", undefined),
  ]);
  assert.deepEqual(rows.map((r) => [r.key, r.ms / MIN]), [
    ["coucou @ main", 25], ["coucou @ fix-x", 7], ["notes", 2],
  ]);
  assert.equal(rows[0].issue, undefined);
});

test("an issue linked after the session started still gets the first minutes", () => {
  const rows = aggregate([
    ev("a", "start", t(9), null), ev("a", "prompt", t(9, 2), SHO475), ev("a", "stop", t(9, 12), SHO475),
  ]);
  assert.deepEqual(rows.map((r) => [r.key, r.ms / MIN]), [["SHO-475", 12]]);
});

test("a span crossing midnight is split between the two days", () => {
  const rows = aggregate([
    ev("a", "prompt", t(23, 50)), ev("a", "activity", t(23, 58)), ev("a", "stop", t(0, 6, 17)),
  ]);
  assert.deepEqual(rows.map((r) => [r.day, r.ms / MIN]), [["2026-09-16", 10], ["2026-09-17", 6]]);
});

test("events out of order and from several sessions are sorted per session", () => {
  const rows = aggregate([
    ev("a", "stop", t(9, 30)), ev("b", "prompt", t(14)), ev("a", "prompt", t(9)), ev("b", "stop", t(14, 5)),
  ]);
  assert.deepEqual(minutes(rows), [35]); // same issue, same day: one row
});

test("a stop with nothing before it, and a lone prompt, count nothing", () => {
  assert.deepEqual(aggregate([ev("a", "stop", t(9))]), []);
  assert.deepEqual(aggregate([ev("a", "prompt", t(9))]), []);
  assert.deepEqual(aggregate([]), []);
});

test("the day key is local", () => {
  assert.equal(dayKey(new Date(2026, 0, 5, 0, 0).getTime()), "2026-01-05");
  assert.equal(dayKey(new Date(2026, 0, 5, 23, 59).getTime()), "2026-01-05");
});

test("manual adjustments add, subtract (never below zero) and create entries", () => {
  const base = aggregate([ev("a", "prompt", t(9)), ev("a", "stop", t(9, 30))]);
  const rows = applyAdjustments(base, [
    { day: "2026-09-16", key: "SHO-475", deltaMs: 15 * MIN },
    { day: "2026-09-16", key: "SHO-490", deltaMs: 60 * MIN, title: "Meeting" },
    { day: "2026-09-16", key: "SHO-480", deltaMs: -15 * MIN },
  ]);
  assert.deepEqual(rows.map((r) => [r.key, r.ms / MIN]), [["SHO-490", 60], ["SHO-475", 45]]);
  assert.equal(rows[0].issue?.title, "Meeting");
  const cleared = applyAdjustments(base, [{ day: "2026-09-16", key: "SHO-475", deltaMs: -60 * MIN }]);
  assert.deepEqual(cleared, []);
});

test("half months and period grouping with a one-line description", () => {
  assert.deepEqual(halfMonth(new Date(2026, 8, 3)), { from: "2026-09-01", to: "2026-09-15" });
  assert.deepEqual(halfMonth(new Date(2026, 8, 16)), { from: "2026-09-16", to: "2026-09-30" });
  assert.deepEqual(halfMonth(new Date(2026, 1, 20)), { from: "2026-02-16", to: "2026-02-28" });

  const rows = aggregate([
    ev("a", "prompt", t(9)), ev("a", "stop", t(10)),
    ev("b", "prompt", t(11), SHO480), ev("b", "stop", t(13), SHO480),
    ev("c", "prompt", t(9, 0, 17)), ev("c", "stop", t(9, 30, 17)),
    ev("d", "prompt", t(9, 0, 1)), ev("d", "stop", t(10, 0, 1)),
  ]);
  const days = groupPeriod(rows, "2026-09-16", "2026-09-30");
  assert.deepEqual(days.map((d) => [d.day, d.ms / MIN]), [["2026-09-16", 180], ["2026-09-17", 30]]);
  assert.equal(days[0].description, "SHO-480: Cart bug; SHO-475: PDP redesign");
});

test("text and CSV export", () => {
  const rows = aggregate([
    ev("a", "prompt", t(9)), ev("a", "stop", t(10, 20)),
    ev("b", "prompt", t(11), SHO480), ev("b", "stop", t(12), SHO480),
  ]);
  const days = groupPeriod(rows, "2026-09-01", "2026-09-30");
  assert.equal(
    toText(days),
    "2026-09-16  2.33 h  SHO-475: PDP redesign; SHO-480: Cart bug\nTotal  2.33 h",
  );
  assert.equal(
    toCsv(days),
    [
      "Date,Issue,Title,Repo,Branch,Hours",
      "2026-09-16,SHO-475,PDP redesign,shop,feat/sho-475,1.33",
      "2026-09-16,SHO-480,Cart bug,shop,feat/sho-475,1.00",
      "",
    ].join("\n"),
  );
  assert.equal(
    toCsv(days, "day", { roundMinutes: 15 }),
    "Date,Hours,Description\n2026-09-16,2.25,SHO-475: PDP redesign; SHO-480: Cart bug\n",
  );
  assert.equal(toText([]), "");
});

test("CSV cells are quoted and spreadsheet formulas are defused", () => {
  assert.equal(csvCell('Fix "cart", again'), '"Fix ""cart"", again"');
  assert.equal(csvCell("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"");
  assert.equal(csvCell("-1 day"), "'-1 day");
  assert.equal(csvCell(-1.5), "-1.5");
  assert.equal(csvCell("line\nbreak"), '"line\nbreak"');
});

test("the store round-trips, ignores garbage and keeps its rows", () => {
  let s = EMPTY_STORE;
  s = recordEvent(s, ev("a", "prompt", t(9)));
  s = recordEvent(s, ev("a", "stop", t(9, 30)));
  s = addAdjustment(s, { day: "2026-09-16", key: "SHO-475", deltaMs: 15 * MIN });
  const back = parseStore(serializeStore(s));
  assert.deepEqual(back, s);
  assert.deepEqual(minutes(rowsFromStore(back)), [45]);

  assert.deepEqual(parseStore("not json").events, []);
  assert.deepEqual(parseStore(null).events, []);
  const dirty = parseStore(JSON.stringify({
    events: [{ session: "a", kind: "nope", at: 1 }, { session: "a", kind: "stop", at: "x" }, null, ev("a", "stop", 5, null)],
    adjustments: [{ day: "d", key: "k" }, { day: "2026-09-16", key: "k", deltaMs: 1 }],
  }));
  assert.equal(dirty.events.length, 1);
  assert.equal(dirty.adjustments.length, 1);
  assert.equal(EMPTY_STORE.events.length, 0); // EMPTY_STORE is never mutated
});

test("activity bursts are folded into one event without changing the time", () => {
  let burst = EMPTY_STORE;
  let full: TimeEvent[] = [];
  burst = recordEvent(burst, ev("a", "prompt", t(9)));
  full.push(ev("a", "prompt", t(9)));
  for (let s = 10; s <= 300; s += 10) {
    const e = ev("a", "activity", t(9) + s * 1000);
    burst = recordEvent(burst, e);
    full.push(e);
  }
  burst = recordEvent(burst, ev("a", "stop", t(9, 6)));
  full.push(ev("a", "stop", t(9, 6)));
  assert.ok(burst.events.length < 5);
  assert.deepEqual(aggregate(burst.events), aggregate(full));
});

test("old events are dropped, adjustments of the same day and key are summed", () => {
  const now = t(9);
  let s = recordEvent(EMPTY_STORE, ev("a", "prompt", now - (KEEP_DAYS + 1) * 86_400_000), now);
  s = recordEvent(s, ev("a", "prompt", now), now);
  assert.equal(s.events.length, 1);
  s = addAdjustment(s, { day: "d", key: "k", deltaMs: 15 * MIN });
  s = addAdjustment(s, { day: "d", key: "k", deltaMs: 15 * MIN });
  assert.equal(s.adjustments[0].deltaMs, 30 * MIN);
  s = addAdjustment(s, { day: "d", key: "k", deltaMs: -30 * MIN });
  assert.deepEqual(s.adjustments, []);
});
