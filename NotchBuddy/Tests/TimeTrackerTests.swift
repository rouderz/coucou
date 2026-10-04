import XCTest
@testable import Coucou

/// Time per Linear issue (#114): hook events → time events, half-month periods, durations.
final class TimeTrackerTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }()

    func testHookEventsMapToTimeEvents() {
        XCTAssertEqual(TimeTracker.kind(hook: "SessionStart", payload: [:]), .start)
        XCTAssertEqual(TimeTracker.kind(hook: "UserPromptSubmit", payload: [:]), .prompt)
        XCTAssertEqual(TimeTracker.kind(hook: "PreToolUse", payload: [:]), .activity)
        XCTAssertEqual(TimeTracker.kind(hook: "PostToolUse", payload: [:]), .activity)
        XCTAssertEqual(TimeTracker.kind(hook: "PermissionRequest", payload: [:]), .activity)
        XCTAssertEqual(TimeTracker.kind(hook: "Stop", payload: [:]), .stop)
        XCTAssertEqual(TimeTracker.kind(hook: "SessionEnd", payload: [:]), .stop)
        XCTAssertEqual(TimeTracker.kind(hook: "Notification", payload: ["notification_type": "idle_prompt"]), .idle)
        XCTAssertEqual(TimeTracker.kind(hook: "Notification", payload: ["message": "Claude is waiting for your input"]), .idle)
        XCTAssertNil(TimeTracker.kind(hook: "Notification", payload: ["message": "Claude needs your permission to use Bash"]))
        XCTAssertNil(TimeTracker.kind(hook: "StatusLine", payload: [:]))
        XCTAssertNil(TimeTracker.kind(hook: "EditorContext", payload: [:]))
    }

    func testRecentPeriodsGoBackByHalfMonths() {
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 10))!
        let p = TimeTracker.recentPeriods(before: now, count: 4, calendar: cal)
        XCTAssertEqual(p.map(\.from), ["2026-03-01", "2026-02-16", "2026-02-01", "2026-01-16"])
        XCTAssertEqual(p.map(\.to), ["2026-03-15", "2026-02-28", "2026-02-15", "2026-01-31"])
    }

    func testDayParsesAndDurationFormats() {
        let d = TimeTracker.day("2026-09-16", calendar: cal)!
        XCTAssertEqual(TimeTracking.dayKey(d, calendar: cal), "2026-09-16")
        XCTAssertNil(TimeTracker.day("nope", calendar: cal))
        XCTAssertEqual(TimeTracker.duration(65 * 60), "1h 05m")
        XCTAssertEqual(TimeTracker.duration(0), "0h 00m")
    }
}
