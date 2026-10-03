// Payday (#110): when the next pay is, and whether the last one arrived.
// Dates are plain "YYYY-MM-DD" days (no time zones). Gusto pays on the business day before a
// weekend payday; holidays are not known here, so a holiday list can be passed in.
// Mirrors NotchBuddy/Sources/App/Payday.swift.

export type PaySchedule =
  | { kind: "semimonthly"; days: [number, number] } // 1–31; 31 = the last day of the month
  | { kind: "monthly"; day: number }
  | { kind: "biweekly"; anchor: string } // any known payday
  | { kind: "weekly"; anchor: string };

export type PaydayStatus =
  | { kind: "paid"; date: string }
  | { kind: "dueToday" }
  | { kind: "late"; expected: string; daysLate: number }
  | { kind: "upcoming"; date: string; inDays: number };

/** After this many days without a pay mail the pill stops saying "late" and looks ahead again. */
const LATE_DAYS = 5;

/** The Gmail search the Gusto preset uses. */
export const GUSTO_QUERY = "from:gusto.com (paystub OR paid) newer_than:7d";

// ── civil dates ↔ day numbers (proleptic Gregorian, days since 1970-01-01) ────────────────────

export function toDays(date: string): number {
  const [y, m, d] = date.split("-").map(Number);
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor(yy / 400);
  const yoe = yy - era * 400;
  const doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}

export function fromDays(days: number): string {
  const z = days + 719468;
  const era = Math.floor(z / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp + (mp < 10 ? 3 : -9);
  const y = yoe + era * 400 + (m <= 2 ? 1 : 0);
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

/** 0 = Sunday … 6 = Saturday. */
function weekday(days: number): number {
  return (((days + 4) % 7) + 7) % 7;
}

function daysInMonth(y: number, m: number): number {
  return toDays(m === 12 ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, "0")}-01`) - toDays(`${y}-${String(m).padStart(2, "0")}-01`);
}

function ymd(y: number, m: number, d: number): number {
  return toDays(`${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`);
}

/** Moves a weekend or holiday payday back to the previous business day. */
function shift(days: number, holidays: Set<number>): number {
  let d = days;
  while (weekday(d) === 0 || weekday(d) === 6 || holidays.has(d)) d -= 1;
  return d;
}

/** Every adjusted payday between two day numbers (inclusive), in order. */
function paydaysBetween(schedule: PaySchedule, from: number, to: number, holidays: Set<number>): number[] {
  const out = new Set<number>();
  if (schedule.kind === "biweekly" || schedule.kind === "weekly") {
    const step = schedule.kind === "weekly" ? 7 : 14;
    const anchor = toDays(schedule.anchor);
    // Start a few steps early: the shift can move a payday before `from`.
    let d = anchor + Math.floor((from - 7 - anchor) / step) * step;
    for (; d <= to + 7; d += step) {
      const adjusted = shift(d, holidays);
      if (adjusted >= from && adjusted <= to) out.add(adjusted);
    }
  } else {
    const days = schedule.kind === "monthly" ? [schedule.day] : schedule.days;
    const [fy, fm] = fromDays(from).split("-").map(Number);
    let y = fy;
    let m = fm - 1;
    if (m < 1) { m = 12; y -= 1; }
    for (let i = 0; i < 40; i++) {
      for (const day of days) {
        const nominal = ymd(y, m, Math.min(day, daysInMonth(y, m)));
        const adjusted = shift(nominal, holidays);
        if (adjusted >= from && adjusted <= to) out.add(adjusted);
      }
      m += 1;
      if (m > 12) { m = 1; y += 1; }
      if (ymd(y, m, 1) > to + 31) break;
    }
  }
  return [...out].sort((a, b) => a - b);
}

/** The first payday on or after `from`. */
export function nextPayday(schedule: PaySchedule, from: string, holidays: string[] = []): string {
  const start = toDays(from);
  const h = new Set(holidays.map(toDays));
  return fromDays(paydaysBetween(schedule, start, start + 100, h)[0]);
}

/** The last payday on or before `from`. */
export function previousPayday(schedule: PaySchedule, from: string, holidays: string[] = []): string {
  const end = toDays(from);
  const h = new Set(holidays.map(toDays));
  const all = paydaysBetween(schedule, end - 100, end, h);
  return fromDays(all[all.length - 1]);
}

/**
 * What the pill says. `paidDates` are the days Gusto's mails arrived (from the Gmail search).
 * A mail up to 2 days before the payday counts for it (pay stubs are often sent ahead).
 */
export function paydayStatus(schedule: PaySchedule, today: string, paidDates: string[], holidays: string[] = []): PaydayStatus {
  const now = toDays(today);
  const last = toDays(previousPayday(schedule, today, holidays));
  const mail = paidDates.map(toDays).filter((d) => d >= last - 2 && d <= now).sort((a, b) => b - a)[0];
  if (mail !== undefined && now - last <= 3) return { kind: "paid", date: fromDays(mail) };
  if (mail === undefined && now === last) return { kind: "dueToday" };
  if (mail === undefined && now > last && now - last <= LATE_DAYS) return { kind: "late", expected: fromDays(last), daysLate: now - last };
  const next = nextPayday(schedule, fromDays(now + 1), holidays);
  return { kind: "upcoming", date: next, inDays: toDays(next) - now };
}
