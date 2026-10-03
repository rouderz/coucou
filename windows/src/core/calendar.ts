// Google Calendar (#116): the next-meeting pill, join links and "do not disturb during
// meetings". Pure logic only (no network, no DOM) so it is tested here and mirrored in
// NotchBuddy/Sources/App/GoogleCalendar.swift. The poller (events.list every 5 min) and the
// timers live elsewhere and just feed `parseEvents` / `nextWake`.

/** The parts of a Google Calendar `Event` resource this reads. */
export interface GEvent {
  id?: string;
  status?: string; // confirmed | tentative | cancelled
  summary?: string;
  location?: string;
  description?: string;
  hangoutLink?: string;
  htmlLink?: string;
  transparency?: string; // "transparent" = shown as Free
  start?: { dateTime?: string; date?: string; timeZone?: string };
  end?: { dateTime?: string; date?: string; timeZone?: string };
  attendees?: { self?: boolean; responseStatus?: string }[];
  conferenceData?: { entryPoints?: { entryPointType?: string; uri?: string }[] };
}

export type JoinKind = "meet" | "zoom" | "teams";
export interface JoinLink { kind: JoinKind; url: string }

export interface Meeting {
  id: string;
  title: string;
  start: number; // ms; all-day: local midnight
  end: number;
  allDay: boolean;
  busy: boolean;
  calendarId?: string;
  join: JoinLink | null;
  htmlLink?: string;
}

const URL_RE = /https?:\/\/[^\s<>"'\\)]+/gi;

function classify(url: string): JoinKind | null {
  let u: URL;
  try { u = new URL(url); } catch { return null; }
  const host = u.hostname.toLowerCase();
  if (host === "meet.google.com" && /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}\/?$/i.test(u.pathname)) return "meet";
  if ((host === "zoom.us" || host.endsWith(".zoom.us") || host.endsWith(".zoomgov.com")) && /^\/(j|my|wc\/join)\//.test(u.pathname)) return "zoom";
  if (host === "teams.microsoft.com" && u.pathname.startsWith("/l/meetup-join/")) return "teams";
  if (host === "teams.live.com" && u.pathname.startsWith("/meet/")) return "teams";
  return null;
}

function urlsIn(text: string | undefined): string[] {
  if (!text) return [];
  // Descriptions can be HTML: href="…&amp;…" and <a>…</a>.
  const plain = text.replace(/&amp;/g, "&");
  const found = plain.match(URL_RE) ?? [];
  return found.map((s) => s.replace(/[.,;:!?\]]+$/, ""));
}

/** Meet / Zoom / Teams link of an event: conference data first, then location, then description. */
export function parseJoinLink(e: Pick<GEvent, "conferenceData" | "hangoutLink" | "location" | "description">): JoinLink | null {
  const candidates: string[] = [];
  for (const p of e.conferenceData?.entryPoints ?? []) {
    if (p.entryPointType === "video" && p.uri) candidates.push(p.uri);
  }
  if (e.hangoutLink) candidates.push(e.hangoutLink);
  candidates.push(...urlsIn(e.location), ...urlsIn(e.description));
  for (const url of candidates) {
    const kind = classify(url);
    if (kind) return { kind, url };
  }
  return null;
}

/** "2026-10-03" → local midnight (all-day dates have no zone: they mean the user's day). */
function localDay(date: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])).getTime() : null;
}

/**
 * One API event → Meeting, or null when it never counts: cancelled, declined by the user,
 * or without a readable start/end. `dateTime` carries its own UTC offset, so the instant is
 * right whatever time zone the event or the user is in.
 */
export function toMeeting(e: GEvent, calendarId?: string): Meeting | null {
  if (e.status === "cancelled") return null;
  if (e.attendees?.some((a) => a.self && a.responseStatus === "declined")) return null;
  let start: number | null, end: number | null, allDay = false;
  if (e.start?.dateTime && e.end?.dateTime) {
    start = Date.parse(e.start.dateTime);
    end = Date.parse(e.end.dateTime);
  } else if (e.start?.date && e.end?.date) {
    allDay = true;
    start = localDay(e.start.date);
    end = localDay(e.end.date);
  } else return null;
  if (start === null || end === null || Number.isNaN(start) || Number.isNaN(end) || end < start) return null;
  return {
    id: e.id ?? `${start}-${e.summary ?? ""}`,
    title: (e.summary ?? "").trim() || "(No title)",
    start, end, allDay,
    busy: e.transparency !== "transparent",
    calendarId,
    join: parseJoinLink(e),
    htmlLink: e.htmlLink,
  };
}

export function parseEvents(events: GEvent[], calendarId?: string): Meeting[] {
  return events.map((e) => toMeeting(e, calendarId)).filter((m): m is Meeting => m !== null)
    .sort((a, b) => a.start - b.start || a.end - b.end);
}

/** Keep the chosen calendars; `null` = all of them. */
export function inCalendars(meetings: Meeting[], enabled: string[] | null): Meeting[] {
  return enabled === null ? meetings : meetings.filter((m) => m.calendarId !== undefined && enabled.includes(m.calendarId));
}

/** Timed events only: all-day events are not meetings. */
function timed(meetings: Meeting[]): Meeting[] {
  return meetings.filter((m) => !m.allDay && m.end > m.start);
}

export type MeetingState =
  | { kind: "now"; meeting: Meeting }
  | { kind: "next"; meeting: Meeting; inMs: number }
  | null;

/**
 * What the pill shows: the meeting in progress (ending soonest), else the next one to start
 * within `horizonMs`. With `busyOnly`, "Free" events are ignored.
 */
export function pickMeeting(meetings: Meeting[], now: number, horizonMs = 60 * 60_000, busyOnly = true): MeetingState {
  const list = timed(meetings).filter((m) => !busyOnly || m.busy);
  const current = list.filter((m) => m.start <= now && now < m.end).sort((a, b) => a.end - b.end)[0];
  if (current) return { kind: "now", meeting: current };
  const next = list.filter((m) => m.start > now).sort((a, b) => a.start - b.start)[0];
  if (next && next.start - now <= horizonMs) return { kind: "next", meeting: next, inMs: next.start - now };
  return null;
}

export function clock(ms: number): string {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/** "in 12 min", "in 1 h", "in 1 h 5 min"; rounds up so it never says 0. */
export function inText(ms: number): string {
  const min = Math.max(1, Math.ceil(ms / 60_000));
  if (min < 60) return `in ${min} min`;
  const h = Math.floor(min / 60), r = min % 60;
  return r === 0 ? `in ${h} h` : `in ${h} h ${r} min`;
}

/** "Standup in 12 min" / "Now: Standup (until 10:15)"; null when there is nothing to show. */
export function pillText(state: MeetingState): string | null {
  if (!state) return null;
  if (state.kind === "now") return `Now: ${state.meeting.title} (until ${clock(state.meeting.end)})`;
  return `${state.meeting.title} ${inText(state.inMs)}`;
}

/**
 * Do not disturb during meetings: until when, or null. Only busy, timed events count (same rule as
 * macOS); back-to-back or overlapping meetings are one stretch, so it doesn't flicker off between them.
 */
export function dndUntil(meetings: Meeting[], now: number): number | null {
  const busy = timed(meetings).filter((m) => m.busy).sort((a, b) => a.start - b.start);
  let until: number | null = null;
  for (const m of busy) {
    if (until === null) {
      if (m.start <= now && now < m.end) until = m.end;
    } else if (m.start <= until) {
      until = Math.max(until, m.end);
    }
  }
  return until;
}

/** The next moment something changes (a start, an end, or a heads-up), for one wake-up timer. */
export function nextWake(meetings: Meeting[], now: number, headsUpMs = 5 * 60_000): number | null {
  let best: number | null = null;
  for (const m of timed(meetings)) {
    for (const t of [m.start - headsUpMs, m.start, m.end]) {
      if (t > now && (best === null || t < best)) best = t;
    }
  }
  return best;
}

/** Meetings whose heads-up is due: starting within `headsUpMs`, not yet announced. */
export function headsUpDue(meetings: Meeting[], now: number, announced: ReadonlySet<string>, headsUpMs = 5 * 60_000): Meeting[] {
  return timed(meetings).filter((m) => m.busy && m.start > now && m.start - now <= headsUpMs && !announced.has(m.id));
}
