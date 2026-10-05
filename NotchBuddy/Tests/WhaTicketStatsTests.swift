import XCTest
@testable import Coucou

/// WhaTicket stats: the arrival / accept log and the numbers drawn from it.
final class WhaTicketStatsTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-10-04 at hh:mm UTC.
    private func at(_ h: Int, _ m: Int = 0, day: Int = 4) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    private func seen(_ id: String, queue: String = "Soporte") -> WhaTicketTracker.Seen {
        .init(id: id, queueId: "q-" + queue, queue: queue, channel: nil)
    }

    func testArrivalsAndAccepts() {
        var t = WhaTicketTracker()
        XCTAssertTrue(t.observe(pending: [seen("a"), seen("b")], mine: [], backlog: false, now: at(9), day: "2026-10-04"))
        // Same snapshot again: nothing new, nothing written.
        XCTAssertFalse(t.observe(pending: [seen("a"), seen("b")], mine: [], backlog: false, now: at(9, 1), day: "2026-10-04"))
        // "a" accepted from Coucou, then it shows in mine: logged once, as a click.
        XCTAssertTrue(t.accept("a", how: "click", now: at(9, 5), day: "2026-10-04"))
        XCTAssertFalse(t.observe(pending: [seen("b")], mine: ["a"], backlog: false, now: at(9, 6), day: "2026-10-04"))
        // "b" taken in the web app.
        XCTAssertTrue(t.observe(pending: [], mine: ["a", "b"], backlog: false, now: at(9, 10), day: "2026-10-04"))
        let accepted = t.events.filter { $0.kind == "accepted" }
        XCTAssertEqual(accepted.map(\.how), ["click", "web"])
        XCTAssertEqual(accepted.map(\.wait), [300, 600])
        XCTAssertEqual(accepted[0].queue, "Soporte")
        // A ticket that never waited in the queue isn't an accept.
        XCTAssertFalse(t.observe(pending: [], mine: ["c"], backlog: false, now: at(9, 11), day: "2026-10-04"))
    }

    func testOncePerDayAndBacklog() {
        var t = WhaTicketTracker()
        _ = t.observe(pending: [seen("a")], mine: [], backlog: true, now: at(8), day: "2026-10-04")
        XCTAssertEqual(t.events.first?.backlog, true)
        _ = t.accept("a", how: "auto", now: at(8, 30), day: "2026-10-04")
        XCTAssertNil(t.events.last?.wait, "a backlog ticket has no known wait")
        // Back in the queue and accepted again the same day: counted once.
        XCTAssertFalse(t.observe(pending: [seen("a")], mine: [], backlog: false, now: at(10), day: "2026-10-04"))
        XCTAssertFalse(t.accept("a", how: "click", now: at(10, 5), day: "2026-10-04"))
        XCTAssertEqual(t.events.count, 2)
        // The next day it counts again.
        XCTAssertTrue(t.observe(pending: [seen("a")], mine: [], backlog: false, now: at(9, day: 5), day: "2026-10-05"))
    }

    func testReloadKeepsOpenTicketsAndPrunes() {
        var t = WhaTicketTracker()
        _ = t.observe(pending: [seen("a")], mine: [], backlog: false, now: at(9), day: "2026-10-04")
        var again = WhaTicketTracker(events: t.events)
        XCTAssertTrue(again.accept("a", how: "web", now: at(9, 2), day: "2026-10-04"))
        XCTAssertEqual(again.events.last?.wait, 120)
        XCTAssertFalse(again.prune(now: at(9, day: 5)))
        XCTAssertTrue(again.prune(now: at(9).addingTimeInterval(366 * 86_400)))
        XCTAssertTrue(again.events.isEmpty)
    }

    func testSummary() {
        var t = WhaTicketTracker()
        _ = t.observe(pending: [seen("y")], mine: [], backlog: false, now: at(10, day: 3), day: "2026-10-03")
        _ = t.observe(pending: [seen("old")], mine: [], backlog: true, now: at(8), day: "2026-10-04")
        _ = t.observe(pending: [seen("old"), seen("a"), seen("b", queue: "Ventas")], mine: [], backlog: false, now: at(9), day: "2026-10-04")
        _ = t.accept("a", how: "auto", now: at(9, 1), day: "2026-10-04")
        _ = t.accept("b", how: "click", now: at(9, 3), day: "2026-10-04")
        _ = t.observe(pending: [], mine: ["old"], backlog: false, now: at(14), day: "2026-10-04")

        let r = WhaTicketStats.range(.today, now: at(15), calendar: cal)
        let s = WhaTicketStats.summary(t.events, from: r.from, to: r.to, calendar: cal)
        XCTAssertEqual(s.arrived, 3)
        XCTAssertEqual(s.backlog, 1)
        XCTAssertEqual(s.accepted, 3)
        XCTAssertEqual([s.click, s.auto, s.web], [1, 1, 1])
        XCTAssertEqual(s.rate, 1)
        XCTAssertEqual(s.averageWait, 120)
        XCTAssertEqual(s.medianWait, 120)
        XCTAssertEqual(s.hours[8].arrived, 0, "backlog stays out of the per-hour chart")
        XCTAssertEqual(s.hours[9].arrived, 2)
        XCTAssertEqual(s.hours[14].accepted, 1)
        XCTAssertEqual(s.queues.map(\.name), ["Soporte", "Ventas"])
        XCTAssertEqual(s.queues[0].arrived, 2)
        XCTAssertEqual(s.days.map(\.day), ["2026-10-04"])

        let week = WhaTicketStats.range(.week, now: at(15), calendar: cal)
        let w = WhaTicketStats.summary(t.events, from: week.from, to: week.to, calendar: cal)
        XCTAssertEqual(w.days.count, 7)
        XCTAssertEqual(w.arrived, 4)
        XCTAssertEqual(w.days[5].arrived, 1)

        let custom = WhaTicketStats.range(.custom, now: at(15), from: at(0, day: 4), to: at(0, day: 3), calendar: cal)
        XCTAssertEqual(custom.from, at(0, day: 3))
        XCTAssertEqual(custom.to, at(0, day: 5))

        let today = WhaTicketStats.today(t.events, now: at(15), calendar: cal)
        XCTAssertEqual(today.arrived, 3)
        XCTAssertEqual(today.accepted, 3)
        XCTAssertEqual(today.auto, 1)

        let csv = WhaTicketStats.csv(t.events, from: r.from, to: r.to, calendar: cal).split(separator: "\n")
        XCTAssertEqual(csv[0], "date,time,event,how,queue,wait_seconds,ticket")
        XCTAssertEqual(csv[1], "2026-10-04,08:00:00,arrived,backlog,Soporte,,old")
        XCTAssertEqual(csv[4], "2026-10-04,09:01:00,accepted,auto,Soporte,60,a")
    }

    func testHelpers() {
        XCTAssertEqual(WhaTicketStats.median([5, 1, 3]), 3)
        XCTAssertEqual(WhaTicketStats.median([1, 2, 3, 4]), 3)
        XCTAssertNil(WhaTicketStats.median([]))
        XCTAssertEqual(WhaTicketStats.duration(45), "45 s")
        XCTAssertEqual(WhaTicketStats.duration(185), "3 min")
        XCTAssertEqual(WhaTicketStats.duration(3900), "1 h 05 min")
        XCTAssertEqual(WhaTicketStats.duration(nil), "—")
    }
}
