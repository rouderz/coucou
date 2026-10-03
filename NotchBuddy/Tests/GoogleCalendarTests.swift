import XCTest
@testable import Coucou

/// Google Calendar: join links, busy/free, all-day, time zones, pill, do not disturb, timers.
final class GoogleCalendarTests: XCTestCase {
    private func at(_ h: Int, _ m: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: h, minute: m))!
    }
    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    private func event(_ title: String, _ from: Date, _ to: Date, _ extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["id": title, "summary": title, "start": ["dateTime": iso(from)], "end": ["dateTime": iso(to)]]
        for (k, v) in extra { e[k] = v }
        return e
    }
    private let holiday: [String: Any] = ["id": "d", "summary": "Holiday", "start": ["date": "2026-10-03"], "end": ["date": "2026-10-04"]]

    func testJoinLinks() {
        let conf: [String: Any] = ["conferenceData": ["entryPoints": [
            ["entryPointType": "phone", "uri": "tel:+1"], ["entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"]]]]
        XCTAssertEqual(GoogleCalendarLogic.joinLink(conf), JoinLink(kind: .meet, url: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(GoogleCalendarLogic.joinLink(["hangoutLink": "https://meet.google.com/abc-defg-hij"])?.kind, .meet)
        XCTAssertEqual(GoogleCalendarLogic.joinLink(["location": "Zoom: https://us02web.zoom.us/j/123456789?pwd=ab.cd, room 4"]),
                       JoinLink(kind: .zoom, url: "https://us02web.zoom.us/j/123456789?pwd=ab.cd"))
        XCTAssertEqual(GoogleCalendarLogic.joinLink(["description": "<a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=a&amp;b=1\">here</a>"])?.kind, .teams)
        XCTAssertEqual(GoogleCalendarLogic.joinLink(["description": "https://teams.live.com/meet/9312345678901"])?.kind, .teams)
        XCTAssertEqual(GoogleCalendarLogic.joinLink(["location": "https://example.com/agenda", "description": "see https://zoom.us/j/99."])?.url, "https://zoom.us/j/99")
        XCTAssertNil(GoogleCalendarLogic.joinLink(["location": "https://meet.google.com/landing", "description": "https://notzoom.us/j/1"]))
        XCTAssertNil(GoogleCalendarLogic.joinLink(["location": "Room 4, 2nd floor"]))
        XCTAssertNil(GoogleCalendarLogic.joinLink([:]))
    }

    func testBusyFreeDeclinedCancelledAllDay() {
        XCTAssertNil(GoogleCalendarLogic.meeting(event("x", at(9), at(10), ["status": "cancelled"])))
        XCTAssertNil(GoogleCalendarLogic.meeting(event("x", at(9), at(10), ["attendees": [["self": true, "responseStatus": "declined"]]])))
        XCTAssertEqual(GoogleCalendarLogic.meeting(event("x", at(9), at(10), ["attendees": [["self": false, "responseStatus": "declined"]]]))?.busy, true)
        XCTAssertEqual(GoogleCalendarLogic.meeting(event("x", at(9), at(10), ["transparency": "transparent"]))?.busy, false)
        XCTAssertNil(GoogleCalendarLogic.meeting(["summary": "no times"]))
        let day = GoogleCalendarLogic.meeting(holiday)
        XCTAssertEqual(day?.allDay, true)
        XCTAssertEqual(day?.start, at(0))
    }

    func testTimeZonesUseTheOffset() {
        let e: [String: Any] = ["id": "z", "summary": "Sync",
                                "start": ["dateTime": "2026-10-03T10:00:00-05:00", "timeZone": "America/Lima"],
                                "end": ["dateTime": "2026-10-03T10:30:00-05:00", "timeZone": "America/Lima"]]
        let m = GoogleCalendarLogic.meeting(e)
        XCTAssertEqual(m?.start.timeIntervalSince1970, 1_791_039_600)  // 2026-10-03T15:00:00Z
        XCTAssertEqual(m?.end.timeIntervalSince(m!.start), 1800)
        XCTAssertEqual(m?.start, ISO8601DateFormatter().date(from: "2026-10-03T17:00:00+02:00"))
    }

    func testPickAndPillParts() {
        let list = GoogleCalendarLogic.meetings([event("Standup", at(10), at(10, 15)), event("Review", at(14), at(15))])
        guard case .next(let m, let secs)? = GoogleCalendarLogic.pick(list, now: at(9, 48)) else { return XCTFail("expected next") }
        XCTAssertEqual(m.title, "Standup")
        XCTAssertEqual(GoogleCalendarLogic.minutes(secs), 12)
        guard case .now(let current)? = GoogleCalendarLogic.pick(list, now: at(10, 3)) else { return XCTFail("expected now") }
        XCTAssertEqual(current.title, "Standup")
        XCTAssertEqual(GoogleCalendarLogic.clock(current.end), "10:15")
        XCTAssertNil(GoogleCalendarLogic.pick(list, now: at(10, 15)))   // Review is beyond the horizon
        XCTAssertNil(GoogleCalendarLogic.pick(list, now: at(16)))
        XCTAssertEqual(GoogleCalendarLogic.minutes(30), 1)
    }

    func testPickIgnoresAllDayAndFree() {
        let list = GoogleCalendarLogic.meetings([
            holiday,
            event("Focus", at(9), at(12), ["transparency": "transparent"]),
            event("Long", at(9, 30), at(11)),
            event("Short", at(9, 45), at(10)),
        ])
        guard case .now(let m)? = GoogleCalendarLogic.pick(list, now: at(9, 50)) else { return XCTFail("expected now") }
        XCTAssertEqual(m.title, "Short")
        guard case .next(let n, _)? = GoogleCalendarLogic.pick(list, now: at(8, 50)) else { return XCTFail("expected next") }
        XCTAssertEqual(n.title, "Long")
    }

    func testDoNotDisturbDuringMeetings() {
        let list = GoogleCalendarLogic.meetings([
            event("A", at(9), at(10)), event("B", at(10), at(10, 30)), event("C", at(11), at(12)),
            event("Free", at(13), at(14), ["transparency": "transparent"]), holiday,
        ])
        XCTAssertNil(GoogleCalendarLogic.dndUntil(list, now: at(8, 59)))
        XCTAssertEqual(GoogleCalendarLogic.dndUntil(list, now: at(9, 30)), at(10, 30))
        XCTAssertNil(GoogleCalendarLogic.dndUntil(list, now: at(10, 30)))
        XCTAssertEqual(GoogleCalendarLogic.dndUntil(list, now: at(11, 30)), at(12))
        XCTAssertNil(GoogleCalendarLogic.dndUntil(list, now: at(13, 30)))
    }

    func testCalendarChoiceAndTimers() {
        let all = GoogleCalendarLogic.meetings([event("A", at(10), at(11))], calendarId: "work")
            + GoogleCalendarLogic.meetings([event("B", at(10), at(11))], calendarId: "personal")
        XCTAssertEqual(GoogleCalendarLogic.filter(all, calendars: nil).count, 2)
        XCTAssertEqual(GoogleCalendarLogic.filter(all, calendars: ["work"]).map(\.title), ["A"])
        XCTAssertEqual(GoogleCalendarLogic.filter(all, calendars: []).count, 0)

        let list = GoogleCalendarLogic.meetings([event("A", at(10), at(11))])
        XCTAssertEqual(GoogleCalendarLogic.nextWake(list, now: at(8)), at(9, 55))
        XCTAssertEqual(GoogleCalendarLogic.nextWake(list, now: at(9, 56)), at(10))
        XCTAssertEqual(GoogleCalendarLogic.nextWake(list, now: at(10, 1)), at(11))
        XCTAssertNil(GoogleCalendarLogic.nextWake(list, now: at(11)))
        XCTAssertEqual(GoogleCalendarLogic.headsUpDue(list, now: at(9, 56), announced: []).count, 1)
        XCTAssertEqual(GoogleCalendarLogic.headsUpDue(list, now: at(9, 56), announced: ["A"]).count, 0)
        XCTAssertEqual(GoogleCalendarLogic.headsUpDue(list, now: at(10, 1), announced: []).count, 0)
    }
}
