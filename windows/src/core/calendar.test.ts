import { test } from "node:test";
import assert from "node:assert/strict";
import {
  dndUntil, headsUpDue, inCalendars, nextWake, parseEvents, parseJoinLink, pickMeeting, pillText, toMeeting,
  type GEvent,
} from "./calendar.ts";

const at = (h: number, m = 0) => new Date(2026, 9, 3, h, m).getTime();
const ev = (summary: string, from: number, to: number, extra: Partial<GEvent> = {}): GEvent => ({
  id: summary, summary,
  start: { dateTime: new Date(from).toISOString() }, end: { dateTime: new Date(to).toISOString() }, ...extra,
});
const holiday: GEvent = { id: "d", summary: "Holiday", start: { date: "2026-10-03" }, end: { date: "2026-10-04" } };

test("join links: Meet, Zoom and Teams from conference data, location and description", () => {
  assert.deepEqual(parseJoinLink({
    conferenceData: { entryPoints: [{ entryPointType: "phone", uri: "tel:+1" }, { entryPointType: "video", uri: "https://meet.google.com/abc-defg-hij" }] },
  }), { kind: "meet", url: "https://meet.google.com/abc-defg-hij" });
  assert.equal(parseJoinLink({ hangoutLink: "https://meet.google.com/abc-defg-hij" })?.kind, "meet");
  assert.deepEqual(parseJoinLink({ location: "Zoom: https://us02web.zoom.us/j/123456789?pwd=ab.cd, room 4" }),
    { kind: "zoom", url: "https://us02web.zoom.us/j/123456789?pwd=ab.cd" });
  assert.equal(parseJoinLink({ description: "<p>Join <a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=a&amp;b=1\">here</a></p>" })?.kind, "teams");
  assert.equal(parseJoinLink({ description: "https://teams.live.com/meet/9312345678901" })?.kind, "teams");
  // the first recognised link wins, other URLs are ignored
  assert.equal(parseJoinLink({ location: "https://example.com/agenda", description: "see https://zoom.us/j/99." })?.url, "https://zoom.us/j/99");
  assert.equal(parseJoinLink({ location: "https://meet.google.com/landing", description: "https://notzoom.us/j/1" }), null);
  assert.equal(parseJoinLink({ location: "Room 4, 2nd floor" }), null);
  assert.equal(parseJoinLink({}), null);
});

test("busy or free, declined, cancelled and all-day events", () => {
  assert.equal(toMeeting({ ...ev("x", at(9), at(10)), status: "cancelled" }), null);
  assert.equal(toMeeting(ev("x", at(9), at(10), { attendees: [{ self: true, responseStatus: "declined" }] })), null);
  assert.equal(toMeeting(ev("x", at(9), at(10), { attendees: [{ self: false, responseStatus: "declined" }] }))?.busy, true);
  assert.equal(toMeeting(ev("x", at(9), at(10), { transparency: "transparent" }))?.busy, false);
  assert.equal(toMeeting({ summary: "no times" }), null);
  const day = toMeeting(holiday)!;
  assert.ok(day.allDay);
  assert.equal(day.start, at(0));
  assert.equal(day.end, new Date(2026, 9, 4).getTime());
  assert.equal(toMeeting(ev("", at(9), at(10)))?.title, "(No title)");
});

test("time zones: the offset in dateTime decides the instant", () => {
  const m = toMeeting({
    id: "z", summary: "Sync",
    start: { dateTime: "2026-10-03T10:00:00-05:00", timeZone: "America/Lima" },
    end: { dateTime: "2026-10-03T10:30:00-05:00", timeZone: "America/Lima" },
  })!;
  assert.equal(m.start, Date.UTC(2026, 9, 3, 15, 0));
  assert.equal(m.end - m.start, 30 * 60_000);
  assert.equal(m.start, Date.parse("2026-10-03T17:00:00+02:00")); // same instant, written in another zone
});

test("pill: next meeting, meeting in progress, nothing", () => {
  const list = parseEvents([ev("Standup", at(10), at(10, 15)), ev("Review", at(14), at(15))]);
  assert.equal(pillText(pickMeeting(list, at(9, 48))), "Standup in 12 min");
  assert.equal(pillText(pickMeeting(list, at(9, 59))), "Standup in 1 min");
  assert.equal(pillText(pickMeeting(list, at(10, 3))), "Now: Standup (until 10:15)");
  assert.equal(pillText(pickMeeting(list, at(10, 15))), null); // Review is 3h45 away: beyond the horizon
  assert.equal(pillText(pickMeeting(list, at(13, 0))), "Review in 1 h");
  assert.equal(pillText(pickMeeting(list, at(12, 55))), null);
  assert.equal(pillText(pickMeeting(list, at(13, 5))), "Review in 55 min");
  assert.equal(pillText(pickMeeting(list, at(13, 5), 2 * 60 * 60_000)), "Review in 55 min");
  assert.equal(pillText(pickMeeting(list, at(16))), null);
  assert.equal(pillText(null), null);
});

test("pill ignores all-day and Free events, and picks the one ending first when they overlap", () => {
  const list = parseEvents([
    holiday,
    ev("Focus", at(9), at(12), { transparency: "transparent" }),
    ev("Long", at(9, 30), at(11)),
    ev("Short", at(9, 45), at(10)),
  ]);
  assert.equal(pillText(pickMeeting(list, at(9, 50))), "Now: Short (until 10:00)");
  assert.equal(pillText(pickMeeting(list, at(8, 50))), "Long in 40 min");
  assert.equal(pillText(pickMeeting(list, at(8, 50), 60 * 60_000, false)), "Focus in 10 min");
});

test("do not disturb follows busy timed events, back to back as one stretch", () => {
  const list = parseEvents([
    ev("A", at(9), at(10)), ev("B", at(10), at(10, 30)), ev("C", at(11), at(12)),
    ev("Free", at(13), at(14), { transparency: "transparent" }),
    holiday,
  ]);
  assert.equal(dndUntil(list, at(8, 59)), null);
  assert.equal(dndUntil(list, at(9, 30)), at(10, 30));
  assert.equal(dndUntil(list, at(10, 30)), null);
  assert.equal(dndUntil(list, at(11, 30)), at(12));
  assert.equal(dndUntil(list, at(13, 30)), null);
  assert.equal(dndUntil([], at(9)), null);
});

test("per-calendar choice", () => {
  const all = [...parseEvents([ev("A", at(9), at(10))], "work"), ...parseEvents([ev("B", at(9), at(10))], "personal")];
  assert.equal(inCalendars(all, null).length, 2);
  assert.deepEqual(inCalendars(all, ["work"]).map((m) => m.title), ["A"]);
  assert.equal(inCalendars(all, []).length, 0);
});

test("wake-up timer: next heads-up, start or end; heads-up announced once", () => {
  const list = parseEvents([ev("A", at(10), at(11))]);
  assert.equal(nextWake(list, at(8)), at(9, 55));
  assert.equal(nextWake(list, at(9, 56)), at(10));
  assert.equal(nextWake(list, at(10, 1)), at(11));
  assert.equal(nextWake(list, at(11)), null);
  const seen = new Set<string>();
  assert.equal(headsUpDue(list, at(9, 54), seen).length, 0);
  assert.equal(headsUpDue(list, at(9, 56), seen).length, 1);
  seen.add("A");
  assert.equal(headsUpDue(list, at(9, 57), seen).length, 0);
  assert.equal(headsUpDue(list, at(10, 1), new Set()).length, 0); // already started
});
