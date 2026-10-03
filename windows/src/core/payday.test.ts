import { test } from "node:test";
import assert from "node:assert/strict";
import { fromDays, nextPayday, paydayStatus, previousPayday, toDays, type PaySchedule } from "./payday.ts";

const semi: PaySchedule = { kind: "semimonthly", days: [15, 31] };

test("civil date conversion round-trips and knows the weekday", () => {
  assert.equal(toDays("1970-01-01"), 0);
  assert.equal(fromDays(toDays("2026-10-03")), "2026-10-03");
  assert.equal(fromDays(toDays("2024-02-29") + 1), "2024-03-01");
  assert.equal(toDays("2026-10-04") - toDays("2026-10-03"), 1);
});

test("semi-monthly: 15th and last day, weekend paydays move back to Friday", () => {
  // 15 Aug 2026 is a Saturday → Fri 14; 31 Oct 2026 is a Saturday → Fri 30.
  assert.equal(nextPayday(semi, "2026-08-10"), "2026-08-14");
  assert.equal(nextPayday(semi, "2026-10-16"), "2026-10-30");
  assert.equal(nextPayday(semi, "2026-09-30"), "2026-09-30");
  assert.equal(nextPayday(semi, "2026-10-01"), "2026-10-15");
});

test("a payday that shifts back into the previous month is found", () => {
  // Fri 1 May 2026 is a business day; Sat 1 Aug 2026 → Fri 31 Jul.
  const first: PaySchedule = { kind: "monthly", day: 1 };
  assert.equal(nextPayday(first, "2026-07-20"), "2026-07-31");
  assert.equal(previousPayday(first, "2026-08-15"), "2026-07-31");
});

test("short months clamp the day", () => {
  assert.equal(nextPayday({ kind: "monthly", day: 31 }, "2026-02-01"), "2026-02-27"); // 28 Feb is a Saturday
  assert.equal(nextPayday({ kind: "monthly", day: 30 }, "2026-02-01"), "2026-02-27");
});

test("bi-weekly and weekly follow the anchor", () => {
  const bi: PaySchedule = { kind: "biweekly", anchor: "2026-09-18" }; // a Friday
  assert.equal(nextPayday(bi, "2026-09-19"), "2026-10-02");
  assert.equal(nextPayday(bi, "2026-10-02"), "2026-10-02");
  assert.equal(previousPayday(bi, "2026-10-10"), "2026-10-02");
  assert.equal(nextPayday(bi, "2026-09-01"), "2026-09-04");
  const weekly: PaySchedule = { kind: "weekly", anchor: "2026-09-18" };
  assert.equal(nextPayday(weekly, "2026-09-20"), "2026-09-25");
});

test("holidays move the payday to the business day before", () => {
  // Pay Fri 2026-07-03 is the observed Independence Day holiday → Thu 2 Jul.
  const bi: PaySchedule = { kind: "biweekly", anchor: "2026-06-19" };
  assert.equal(nextPayday(bi, "2026-06-25", ["2026-07-03"]), "2026-07-02");
});

test("status: upcoming, due today, paid, late", () => {
  assert.deepEqual(paydayStatus(semi, "2026-10-12", []), { kind: "upcoming", date: "2026-10-15", inDays: 3 });
  assert.deepEqual(paydayStatus(semi, "2026-10-15", []), { kind: "dueToday" });
  assert.deepEqual(paydayStatus(semi, "2026-10-15", ["2026-10-14"]), { kind: "paid", date: "2026-10-14" });
  assert.deepEqual(paydayStatus(semi, "2026-10-16", []), { kind: "late", expected: "2026-10-15", daysLate: 1 });
});

test("status: a mail from an earlier pay period doesn't count; paid fades into upcoming", () => {
  assert.equal(paydayStatus(semi, "2026-10-16", ["2026-09-30"]).kind, "late");
  assert.deepEqual(paydayStatus(semi, "2026-10-22", ["2026-10-15"]), { kind: "upcoming", date: "2026-10-30", inDays: 8 });
});
