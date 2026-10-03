import XCTest
@testable import Coucou

/// Time per Linear issue (#114): aggregation with overlapping sessions and idle gaps, periods, export, store.
final class TimeTrackingTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }()
    private let sho475 = TimeIssue(identifier: "SHO-475", title: "PDP redesign")
    private let sho480 = TimeIssue(identifier: "SHO-480", title: "Cart bug")

    private func t(_ h: Int, _ m: Int = 0, day: Int = 16) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))!
    }

    private func ev(_ session: String, _ kind: TimeEvent.Kind, _ at: Date, issue: TimeIssue? = nil,
                    repo: String? = "shop", branch: String? = "feat/sho-475", noIssue: Bool = false) -> TimeEvent {
        TimeEvent(session: session, kind: kind, at: at, issue: noIssue ? nil : (issue ?? sho475), repo: repo, branch: branch)
    }

    private func minutes(_ rows: [TimeRow]) -> [Double] { rows.map { $0.seconds / 60 } }
    private func agg(_ e: [TimeEvent], idle: TimeInterval = 600, now: Date? = nil) -> [TimeRow] {
        TimeTracking.aggregate(e, idle: idle, now: now, calendar: cal)
    }

    func testSimpleTurnCountsFromStartToStop() {
        let rows = agg([ev("a", .start, t(9)), ev("a", .prompt, t(9, 1)), ev("a", .stop, t(9, 31))])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].key, "SHO-475")
        XCTAssertEqual(rows[0].day, "2026-09-16")
        XCTAssertEqual(rows[0].seconds, 31 * 60)
    }

    func testTimeAfterStopIsNotCounted() {
        let rows = agg([ev("a", .prompt, t(9)), ev("a", .stop, t(9, 10)), ev("a", .prompt, t(9, 15)), ev("a", .stop, t(9, 20))])
        XCTAssertEqual(minutes(rows), [15])
    }

    func testIdleGapIsNotCounted() {
        let e = [ev("a", .prompt, t(9)), ev("a", .activity, t(9, 5)), ev("a", .activity, t(9, 40)), ev("a", .stop, t(9, 42))]
        XCTAssertEqual(minutes(agg(e, idle: 600)), [7])
        XCTAssertEqual(minutes(agg(e, idle: 3600)), [42])
    }

    func testLongTurnEndingWithStopIsCountedButAbandonedOneIsNot() {
        XCTAssertEqual(minutes(agg([ev("a", .prompt, t(9)), ev("a", .stop, t(9, 45))])), [45])
        XCTAssertEqual(minutes(agg([ev("a", .prompt, t(9)), ev("a", .prompt, t(9, 45)), ev("a", .stop, t(9, 50))])), [5])
    }

    func testGapExactlyAtThresholdIsCounted() {
        XCTAssertEqual(minutes(agg([ev("a", .prompt, t(9)), ev("a", .activity, t(9, 10))])), [10])
    }

    func testIdleEventClosesTheSpan() {
        let e = [ev("a", .prompt, t(9)), ev("a", .idle, t(9, 8)), ev("a", .prompt, t(10)), ev("a", .stop, t(10, 3))]
        XCTAssertEqual(minutes(agg(e)), [11])
    }

    func testOpenSpanCountsUpToNowWhileRecent() {
        let e = [ev("a", .prompt, t(9)), ev("a", .activity, t(9, 4))]
        XCTAssertEqual(minutes(agg(e, now: t(9, 9))), [9])
        XCTAssertEqual(minutes(agg(e, now: t(9, 30))), [4])
        XCTAssertEqual(minutes(agg(e)), [4])
    }

    func testOverlappingSessionsOnTheSameIssueAreMerged() {
        let rows = agg([ev("a", .prompt, t(9)), ev("a", .stop, t(9, 30)), ev("b", .prompt, t(9, 20)), ev("b", .stop, t(9, 50))])
        XCTAssertEqual(minutes(rows), [50])
    }

    func testNestedAndTouchingSessions() {
        XCTAssertEqual(minutes(agg([ev("a", .prompt, t(9)), ev("a", .stop, t(10)),
                                    ev("b", .prompt, t(9, 10)), ev("b", .stop, t(9, 20))])), [60])
        XCTAssertEqual(minutes(agg([ev("a", .prompt, t(9)), ev("a", .stop, t(9, 10)),
                                    ev("b", .prompt, t(9, 10)), ev("b", .stop, t(9, 25))])), [25])
    }

    func testThreeOverlappingSessionsChain() {
        let rows = agg([ev("a", .prompt, t(9)), ev("a", .stop, t(9, 10)),
                        ev("b", .prompt, t(9, 8)), ev("b", .stop, t(9, 20)),
                        ev("c", .prompt, t(9, 19)), ev("c", .stop, t(9, 30))])
        XCTAssertEqual(minutes(rows), [30])
    }

    func testParallelSessionsOnDifferentIssuesKeepTheirTime() {
        let rows = agg([ev("a", .prompt, t(9)), ev("a", .stop, t(9, 30)),
                        ev("b", .prompt, t(9, 10), issue: sho480), ev("b", .stop, t(9, 40), issue: sho480)])
        XCTAssertEqual(rows.map(\.key), ["SHO-475", "SHO-480"])
        XCTAssertEqual(minutes(rows), [30, 30])
    }

    func testSessionsWithoutAnIssueAreGroupedByRepoAndBranch() {
        func n(_ s: String, _ k: TimeEvent.Kind, _ at: Date, _ repo: String, _ branch: String?) -> TimeEvent {
            ev(s, k, at, repo: repo, branch: branch, noIssue: true)
        }
        let rows = agg([n("a", .prompt, t(9), "coucou", "main"), n("a", .stop, t(9, 20), "coucou", "main"),
                        n("b", .prompt, t(10), "coucou", "main"), n("b", .stop, t(10, 5), "coucou", "main"),
                        n("c", .prompt, t(11), "coucou", "fix-x"), n("c", .stop, t(11, 7), "coucou", "fix-x"),
                        n("d", .prompt, t(12), "notes", nil), n("d", .stop, t(12, 2), "notes", nil)])
        XCTAssertEqual(rows.map(\.key), ["coucou @ main", "coucou @ fix-x", "notes"])
        XCTAssertEqual(minutes(rows), [25, 7, 2])
        XCTAssertNil(rows[0].issue)
    }

    func testIssueLinkedAfterTheSessionStartedStillGetsTheFirstMinutes() {
        let rows = agg([ev("a", .start, t(9), noIssue: true), ev("a", .prompt, t(9, 2)), ev("a", .stop, t(9, 12))])
        XCTAssertEqual(rows.map(\.key), ["SHO-475"])
        XCTAssertEqual(minutes(rows), [12])
    }

    func testSpanCrossingMidnightIsSplit() {
        let rows = agg([ev("a", .prompt, t(23, 50)), ev("a", .activity, t(23, 58)), ev("a", .stop, t(0, 6, day: 17))])
        XCTAssertEqual(rows.map(\.day), ["2026-09-16", "2026-09-17"])
        XCTAssertEqual(minutes(rows), [10, 6])
    }

    func testEventsOutOfOrderAreSortedPerSession() {
        let rows = agg([ev("a", .stop, t(9, 30)), ev("b", .prompt, t(14)), ev("a", .prompt, t(9)), ev("b", .stop, t(14, 5))])
        XCTAssertEqual(minutes(rows), [35])
    }

    func testNothingToCount() {
        XCTAssertTrue(agg([]).isEmpty)
        XCTAssertTrue(agg([ev("a", .stop, t(9))]).isEmpty)
        XCTAssertTrue(agg([ev("a", .prompt, t(9))]).isEmpty)
    }

    func testAdjustments() {
        let base = agg([ev("a", .prompt, t(9)), ev("a", .stop, t(9, 30))])
        let rows = TimeTracking.apply([
            TimeAdjustment(day: "2026-09-16", key: "SHO-475", deltaSeconds: 900),
            TimeAdjustment(day: "2026-09-16", key: "SHO-490", deltaSeconds: 3600, title: "Meeting"),
            TimeAdjustment(day: "2026-09-16", key: "SHO-480", deltaSeconds: -900),
        ], to: base)
        XCTAssertEqual(rows.map(\.key), ["SHO-490", "SHO-475"])
        XCTAssertEqual(minutes(rows), [60, 45])
        XCTAssertEqual(rows[0].issue?.title, "Meeting")
        XCTAssertTrue(TimeTracking.apply([TimeAdjustment(day: "2026-09-16", key: "SHO-475", deltaSeconds: -3600)], to: base).isEmpty)
    }

    func testHalfMonthAndPeriodGrouping() {
        XCTAssertEqual(TimeTracking.halfMonth(of: t(9, 0, day: 3), calendar: cal).to, "2026-09-15")
        let second = TimeTracking.halfMonth(of: t(9), calendar: cal)
        XCTAssertEqual(second.from, "2026-09-16")
        XCTAssertEqual(second.to, "2026-09-30")
        let feb = cal.date(from: DateComponents(year: 2026, month: 2, day: 20))!
        XCTAssertEqual(TimeTracking.halfMonth(of: feb, calendar: cal).to, "2026-02-28")

        let rows = agg([ev("a", .prompt, t(9)), ev("a", .stop, t(10)),
                        ev("b", .prompt, t(11), issue: sho480), ev("b", .stop, t(13), issue: sho480),
                        ev("c", .prompt, t(9, 0, day: 17)), ev("c", .stop, t(9, 30, day: 17)),
                        ev("d", .prompt, t(9, 0, day: 1)), ev("d", .stop, t(10, 0, day: 1))])
        let days = TimeTracking.groupPeriod(rows, from: second.from, to: second.to)
        XCTAssertEqual(days.map(\.day), ["2026-09-16", "2026-09-17"])
        XCTAssertEqual(days.map { $0.seconds / 60 }, [180, 30])
        XCTAssertEqual(days[0].description, "SHO-480: Cart bug; SHO-475: PDP redesign")
    }

    func testTextAndCSVExport() {
        let rows = agg([ev("a", .prompt, t(9)), ev("a", .stop, t(10, 20)),
                        ev("b", .prompt, t(11), issue: sho480), ev("b", .stop, t(12), issue: sho480)])
        let days = TimeTracking.groupPeriod(rows, from: "2026-09-01", to: "2026-09-30")
        XCTAssertEqual(TimeTracking.text(days), "2026-09-16  2.33 h  SHO-475: PDP redesign; SHO-480: Cart bug\nTotal  2.33 h")
        XCTAssertEqual(TimeTracking.csv(days), """
        Date,Issue,Title,Repo,Branch,Hours
        2026-09-16,SHO-475,PDP redesign,shop,feat/sho-475,1.33
        2026-09-16,SHO-480,Cart bug,shop,feat/sho-475,1.00

        """)
        XCTAssertEqual(TimeTracking.csv(days, perIssue: false, roundMinutes: 15),
                       "Date,Hours,Description\n2026-09-16,2.25,SHO-475: PDP redesign; SHO-480: Cart bug\n")
        XCTAssertEqual(TimeTracking.text([]), "")
    }

    func testCSVCellsAreQuotedAndFormulasDefused() {
        XCTAssertEqual(TimeTracking.csvCell("Fix \"cart\", again"), "\"Fix \"\"cart\"\", again\"")
        XCTAssertEqual(TimeTracking.csvCell("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(TimeTracking.csvCell("-1 day"), "'-1 day")
        XCTAssertEqual(TimeTracking.csvCell("line\nbreak"), "\"line\nbreak\"")
    }

    func testStoreFoldsActivityBurstsWithoutChangingTheTime() {
        var store = TimeStore()
        var full: [TimeEvent] = []
        let first = ev("a", .prompt, t(9))
        store.record(first); full.append(first)
        for s in stride(from: 10, through: 300, by: 10) {
            let e = ev("a", .activity, t(9).addingTimeInterval(Double(s)))
            store.record(e); full.append(e)
        }
        let stop = ev("a", .stop, t(9, 6))
        store.record(stop); full.append(stop)
        XCTAssertLessThan(store.events.count, 5)
        XCTAssertEqual(agg(store.events), agg(full))
    }

    func testStoreDropsOldEventsAndSumsAdjustments() {
        var store = TimeStore()
        let now = t(9)
        store.record(ev("a", .prompt, now.addingTimeInterval(-Double(TimeTracking.keepDays + 1) * 86_400)), now: now)
        store.record(ev("a", .prompt, now), now: now)
        XCTAssertEqual(store.events.count, 1)
        store.adjust(TimeAdjustment(day: "d", key: "k", deltaSeconds: 900))
        store.adjust(TimeAdjustment(day: "d", key: "k", deltaSeconds: 900))
        XCTAssertEqual(store.adjustments.first?.deltaSeconds, 1800)
        store.adjust(TimeAdjustment(day: "d", key: "k", deltaSeconds: -1800))
        XCTAssertTrue(store.adjustments.isEmpty)
    }

    func testStoreRoundTripsOnDiskAndToleratesGarbage() throws {
        var store = TimeStore()
        store.record(ev("a", .prompt, t(9)))
        store.record(ev("a", .stop, t(9, 30)))
        store.adjust(TimeAdjustment(day: "2026-09-16", key: "SHO-475", deltaSeconds: 900))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("time-tracking.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try store.save(to: url)
        let back = TimeStore.load(from: url)
        XCTAssertEqual(back, store)
        XCTAssertEqual(minutes(back.rows(calendar: cal)), [45])

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(TimeStore.load(from: url), TimeStore())
        XCTAssertEqual(TimeStore.load(from: url.appendingPathExtension("missing")), TimeStore())
    }
}
