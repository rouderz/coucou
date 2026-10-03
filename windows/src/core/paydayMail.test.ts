import { test } from "node:test";
import assert from "node:assert/strict";
import { isGustoPayMail, mailDay, netAmountCents, paidDatesFrom, shouldCheckGmail } from "./paydayMail.ts";
import type { PaySchedule } from "./payday.ts";

const semi: PaySchedule = { kind: "semimonthly", days: [15, 31] };

test("Gusto pay mails yes, reminders and other senders no", () => {
  const f = "Gusto <no-reply@gusto.com>";
  assert.ok(isGustoPayMail({ from: f, subject: "Your paystub is ready", snippet: "" }));
  assert.ok(isGustoPayMail({ from: f, subject: "Payday!", snippet: "" }));
  assert.ok(isGustoPayMail({ from: f, subject: "Hi Ana", snippet: "You've been paid for Oct 1 - Oct 15" }));
  assert.ok(!isGustoPayMail({ from: f, subject: "Reminder: submit your timesheet before payday", snippet: "" }));
  assert.ok(!isGustoPayMail({ from: f, subject: "Welcome to Gusto", snippet: "" }));
  assert.ok(!isGustoPayMail({ from: "Ana <ana@example.com>", subject: "Your paystub is ready", snippet: "" }));
});

test("dates, dedup and the net amount only when stated", () => {
  const noon = new Date(2026, 9, 15, 12).getTime();
  assert.equal(mailDay(noon), "2026-10-15");
  const mails = [
    { from: "gusto.com", subject: "Your paystub is ready", snippet: "", date: noon },
    { from: "gusto.com", subject: "You've been paid", snippet: "", date: noon + 1000 },
    { from: "gusto.com", subject: "Welcome", snippet: "", date: noon - 86400000 * 3 },
  ];
  assert.deepEqual(paidDatesFrom(mails, "gusto"), ["2026-10-15"]);
  assert.equal(paidDatesFrom(mails, "bank").length, 2);
  assert.equal(netAmountCents("Net pay: $1,234.56 deposited"), 123456);
  assert.equal(netAmountCents("Your take-home pay is $980"), 98000);
  assert.equal(netAmountCents("Gross pay $2,000.00"), undefined);
});

test("Gmail is only checked around paydays", () => {
  assert.equal(shouldCheckGmail(semi, "2026-10-08", []), false);
  assert.equal(shouldCheckGmail(semi, "2026-10-13", []), true);
  assert.equal(shouldCheckGmail(semi, "2026-10-15", []), true);
  assert.equal(shouldCheckGmail(semi, "2026-10-16", []), true);
  assert.equal(shouldCheckGmail(semi, "2026-10-15", ["2026-10-14"]), false);
});
