// Do not disturb (#30 on macOS): no sounds, and the island never opens by itself.
// Finished / failed / approval events only badge the pill; approvals still reveal
// it, quietly. Manual: for a while, until tomorrow morning, or until turned off.
// (The macOS calendar mode needs EventKit; there is no equivalent here.)

/** Far future = "until you turn it off". */
export const FOREVER = 8.64e15;

export function dndActive(until: number | null | undefined, now = Date.now()): boolean {
  return typeof until === "number" && until > now;
}

/** Tomorrow at 9:00 local time. */
export function tomorrowMorning(now = new Date()): number {
  const d = new Date(now);
  d.setDate(d.getDate() + 1);
  d.setHours(9, 0, 0, 0);
  return d.getTime();
}

export const DND_CHOICES: { label: string; until: (now: number) => number }[] = [
  { label: "For 30 minutes", until: (now) => now + 30 * 60_000 },
  { label: "For 1 hour", until: (now) => now + 60 * 60_000 },
  { label: "For 3 hours", until: (now) => now + 3 * 60 * 60_000 },
  { label: "Until tomorrow morning", until: (now) => tomorrowMorning(new Date(now)) },
  { label: "Until I turn it off", until: () => FOREVER },
];

/** "On until 18:30", "On until you turn it off"; null when off. */
export function dndStatus(until: number | null | undefined, now = Date.now()): string | null {
  if (!dndActive(until, now)) return null;
  if ((until as number) >= FOREVER) return "On until you turn it off";
  const d = new Date(until as number);
  const sameDay = new Date(now).toDateString() === d.toDateString();
  const time = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  return sameDay ? `On until ${time}` : `On until tomorrow ${time}`;
}
