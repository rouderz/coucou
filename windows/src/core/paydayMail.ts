// Payday (#110): deciding from a Gmail message whether it is a pay mail. Only the sender, subject,
// snippet and date are looked at. Amounts are optional, only read when the mail states the net pay,
// kept in memory and never logged or stored. Mirrors the matcher in NotchBuddy/Sources/App/Payday.swift.

import { paydayStatus, type PaySchedule } from "./payday.ts";

export interface PayMail {
  from: string;
  subject: string;
  snippet: string;
  /** Gmail's internalDate, in milliseconds since the epoch. */
  date: number;
}

const PAY_WORDS = /paystub|pay stub|pay statement|you(?:'|’)ve been paid|you have been paid|you were paid|payday|direct deposit|payment (?:is )?(?:sent|on its way)/i;
// Reminders and admin mails from the same sender that must not count as "paid".
const NOT_PAID = /reminder|upcoming|will be paid|scheduled|is due|timesheet|approve|submit|review your|action required|verify|about to/i;

/** True when a mail from Gusto says the user was paid. */
export function isGustoPayMail(mail: Pick<PayMail, "from" | "subject" | "snippet">): boolean {
  if (!/gusto/i.test(mail.from)) return false;
  if (NOT_PAID.test(mail.subject)) return false;
  return PAY_WORDS.test(mail.subject) || (PAY_WORDS.test(mail.snippet) && !NOT_PAID.test(mail.snippet));
}

/** The local calendar day of a Gmail timestamp. */
export function mailDay(millis: number): string {
  const d = new Date(millis);
  return `${String(d.getFullYear()).padStart(4, "0")}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** The net amount in cents, only when the mail states it. Never guessed from other figures. */
export function netAmountCents(text: string): number | undefined {
  const m = /(?:net (?:pay|amount|wages)|take[- ]home(?: pay)?|deposit(?:ed)? of)\D{0,20}\$\s?(\d{1,3}(?:,\d{3})*|\d+)(?:\.(\d{2}))?/i.exec(text);
  if (!m) return undefined;
  return Number(m[1].replace(/,/g, "")) * 100 + Number(m[2] ?? "0");
}

/**
 * Days with a pay mail, newest first, at most 6. `bank` mails come from the user's own bank
 * search, so the search itself is the filter; Gusto mails are checked by `isGustoPayMail`.
 */
export function paidDatesFrom(mails: PayMail[], source: "gusto" | "bank"): string[] {
  const days = mails.filter((m) => source === "bank" || isGustoPayMail(m)).map((m) => mailDay(m.date));
  return [...new Set(days)].sort().reverse().slice(0, 6);
}

/**
 * Whether Gmail is worth asking right now: from two days before a payday until the pill would stop
 * saying "late", and not once the payment is already seen.
 */
export function shouldCheckGmail(schedule: PaySchedule, today: string, paidDates: string[], holidays: string[] = []): boolean {
  const s = paydayStatus(schedule, today, paidDates, holidays);
  if (s.kind === "paid") return false;
  if (s.kind === "upcoming") return s.inDays <= 2;
  return true;
}
