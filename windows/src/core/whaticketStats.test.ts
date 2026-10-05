import { test } from "node:test";
import assert from "node:assert/strict";
import { duration, median, range, summary, todayLine, toCsv, type StatEvent } from "./whaticketStats.ts";

/** 2026-10-04 (local) at h:m. */
const t = (h: number, m = 0, day = 4) => new Date(2026, 9, day, h, m).getTime();

const arrived = (id: string, at: number, queue = "Soporte", backlog = false): StatEvent =>
  ({ id, kind: "arrived", at, day: "", queueId: `q-${queue}`, queue, ...(backlog ? { backlog: true } : {}) });
const accepted = (id: string, at: number, how: string, wait?: number, queue = "Soporte"): StatEvent =>
  ({ id, kind: "accepted", at, day: "", queueId: `q-${queue}`, queue, how, ...(wait != null ? { wait } : {}) });

const LOG: StatEvent[] = [
  arrived("y", t(10, 0, 3)),
  arrived("old", t(8), "Soporte", true),
  arrived("a", t(9)),
  arrived("b", t(9), "Ventas"),
  accepted("a", t(9, 1), "auto", 60),
  accepted("b", t(9, 3), "click", 180, "Ventas"),
  accepted("old", t(14), "web"),
];

test("today: counts, how, rate and waits", () => {
  const r = range("today", t(15));
  const s = summary(LOG, r.from, r.to);
  assert.equal(s.arrived, 3);
  assert.equal(s.backlog, 1);
  assert.equal(s.accepted, 3);
  assert.deepEqual([s.click, s.auto, s.web], [1, 1, 1]);
  assert.equal(s.rate, 1);
  assert.equal(s.averageWait, 120);
  assert.equal(s.medianWait, 120);
  assert.equal(s.hours[8].arrived, 0, "backlog stays out of the per-hour chart");
  assert.equal(s.hours[9].arrived, 2);
  assert.equal(s.hours[14].accepted, 1);
  assert.deepEqual(s.queues.map((q) => [q.name, q.arrived, q.accepted, q.averageWait]), [
    ["Soporte", 2, 2, 60],
    ["Ventas", 1, 1, 180],
  ]);
  assert.deepEqual(s.days, [{ day: "2026-10-04", arrived: 3, accepted: 3 }]);
});

test("week, month and custom ranges cover whole local days", () => {
  const w = range("week", t(15));
  assert.equal(w.from, new Date(2026, 8, 28).getTime());
  const s = summary(LOG, w.from, w.to);
  assert.equal(s.days.length, 7);
  assert.equal(s.days[0].day, "2026-09-28");
  assert.equal(s.days[5].arrived, 1);
  assert.equal(s.arrived, 4);
  const m = range("month", t(15));
  assert.equal(summary(LOG, m.from, m.to).days.length, 30);
  const c = range("custom", t(15), "2026-10-04", "2026-10-03");
  assert.equal(c.from, t(0, 0, 3));
  assert.equal(c.to, t(0, 0, 5));
  assert.equal(summary([], c.from, c.to).rate, null);
});

test("CSV: one row per event, ticket id included, no names", () => {
  const r = range("today", t(15));
  const lines = toCsv(LOG, r.from, r.to).trim().split("\n");
  assert.equal(lines[0], "date,time,event,how,queue,wait_seconds,ticket");
  assert.equal(lines[1], "2026-10-04,08:00:00,arrived,backlog,Soporte,,old");
  assert.equal(lines[4], "2026-10-04,09:01:00,accepted,auto,Soporte,60,a");
  assert.equal(lines.length, 7);
  assert.match(toCsv([arrived("x", t(9), "=cmd")], r.from, r.to), /,'=cmd,/);
});

test("helpers", () => {
  assert.equal(median([5, 1, 3]), 3);
  assert.equal(median([1, 2, 3, 4]), 3);
  assert.equal(median([]), null);
  assert.equal(duration(45), "45 s");
  assert.equal(duration(185), "3 min");
  assert.equal(duration(3900), "1 h 05 min");
  assert.equal(duration(null), "—");
  assert.equal(todayLine({ arrived: 23, accepted: 18, auto: 5 }), "Today · Arrived 23 · Accepted 18 (5 auto)");
  assert.equal(todayLine(undefined), "Today · Arrived 0 · Accepted 0");
});
