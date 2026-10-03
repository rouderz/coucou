import XCTest
@testable import Coucou

/// Payday: the calculator and the Gmail matcher. Mirrors windows/src/core/payday.test.ts and paydayMail.test.ts.
final class PaydayTests: XCTestCase {
    let semi = PaySchedule.semimonthly(15, 31)

    func testCivilDates() {
        XCTAssertEqual(Payday.toDays("1970-01-01"), 0)
        XCTAssertEqual(Payday.fromDays(Payday.toDays("2026-10-03")), "2026-10-03")
        XCTAssertEqual(Payday.fromDays(Payday.toDays("2024-02-29") + 1), "2024-03-01")
        XCTAssertEqual(Payday.toDays("2026-10-04") - Payday.toDays("2026-10-03"), 1)
        XCTAssertEqual(Payday.fromDays(-1), "1969-12-31")
    }

    func testSemiMonthlyShiftsWeekendsBack() {
        XCTAssertEqual(Payday.nextPayday(semi, from: "2026-08-10"), "2026-08-14")
        XCTAssertEqual(Payday.nextPayday(semi, from: "2026-10-16"), "2026-10-30")
        XCTAssertEqual(Payday.nextPayday(semi, from: "2026-09-30"), "2026-09-30")
        XCTAssertEqual(Payday.nextPayday(semi, from: "2026-10-01"), "2026-10-15")
    }

    func testShiftBackIntoPreviousMonth() {
        let first = PaySchedule.monthly(1)
        XCTAssertEqual(Payday.nextPayday(first, from: "2026-07-20"), "2026-07-31")
        XCTAssertEqual(Payday.previousPayday(first, from: "2026-08-15"), "2026-07-31")
    }

    func testShortMonthsClamp() {
        XCTAssertEqual(Payday.nextPayday(.monthly(31), from: "2026-02-01"), "2026-02-27")
        XCTAssertEqual(Payday.nextPayday(.monthly(30), from: "2026-02-01"), "2026-02-27")
    }

    func testBiweeklyAndWeekly() {
        let bi = PaySchedule.biweekly(anchor: "2026-09-18")
        XCTAssertEqual(Payday.nextPayday(bi, from: "2026-09-19"), "2026-10-02")
        XCTAssertEqual(Payday.nextPayday(bi, from: "2026-10-02"), "2026-10-02")
        XCTAssertEqual(Payday.previousPayday(bi, from: "2026-10-10"), "2026-10-02")
        XCTAssertEqual(Payday.nextPayday(bi, from: "2026-09-01"), "2026-09-04")
        XCTAssertEqual(Payday.nextPayday(.weekly(anchor: "2026-09-18"), from: "2026-09-20"), "2026-09-25")
    }

    func testHolidaysMoveBack() {
        let bi = PaySchedule.biweekly(anchor: "2026-06-19")
        XCTAssertEqual(Payday.nextPayday(bi, from: "2026-06-25", holidays: ["2026-07-03"]), "2026-07-02")
    }

    func testStatus() {
        XCTAssertEqual(Payday.status(semi, today: "2026-10-12", paidDates: []), .upcoming(date: "2026-10-15", inDays: 3))
        XCTAssertEqual(Payday.status(semi, today: "2026-10-15", paidDates: []), .dueToday)
        XCTAssertEqual(Payday.status(semi, today: "2026-10-15", paidDates: ["2026-10-14"]), .paid(date: "2026-10-14"))
        XCTAssertEqual(Payday.status(semi, today: "2026-10-16", paidDates: []), .late(expected: "2026-10-15", daysLate: 1))
        XCTAssertEqual(Payday.status(semi, today: "2026-10-16", paidDates: ["2026-09-30"]), .late(expected: "2026-10-15", daysLate: 1))
        XCTAssertEqual(Payday.status(semi, today: "2026-10-22", paidDates: ["2026-10-15"]), .upcoming(date: "2026-10-30", inDays: 8))
    }

    func testGustoMatcher() {
        let f = "Gusto <no-reply@gusto.com>"
        XCTAssertTrue(Payday.isGustoPayMail(from: f, subject: "Your paystub is ready", snippet: ""))
        XCTAssertTrue(Payday.isGustoPayMail(from: f, subject: "Payday!", snippet: ""))
        XCTAssertTrue(Payday.isGustoPayMail(from: f, subject: "Hi Ana", snippet: "You've been paid for Oct 1 - Oct 15"))
        XCTAssertFalse(Payday.isGustoPayMail(from: f, subject: "Reminder: submit your timesheet before payday", snippet: ""))
        XCTAssertFalse(Payday.isGustoPayMail(from: f, subject: "Welcome to Gusto", snippet: ""))
        XCTAssertFalse(Payday.isGustoPayMail(from: "Ana <ana@example.com>", subject: "Your paystub is ready", snippet: ""))
    }

    func testPaidDatesAndAmount() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        func mail(_ subject: String, _ date: Date) -> GmailMessage {
            GmailMessage(id: subject, threadId: subject, from: "gusto.com", subject: subject, snippet: "", date: date)
        }
        let mails = [mail("Your paystub is ready", noon), mail("You've been paid", noon.addingTimeInterval(1)),
                     mail("Welcome", noon.addingTimeInterval(-3 * 86400))]
        XCTAssertEqual(Payday.paidDates(from: mails, source: .gusto, calendar: cal), ["2026-10-15"])
        XCTAssertEqual(Payday.paidDates(from: mails, source: .bank, calendar: cal).count, 2)
        XCTAssertEqual(Payday.netAmountCents("Net pay: $1,234.56 deposited"), 123456)
        XCTAssertEqual(Payday.netAmountCents("Your take-home pay is $980"), 98000)
        XCTAssertNil(Payday.netAmountCents("Gross pay $2,000.00"))
    }

    func testOnlyChecksAroundPaydays() {
        XCTAssertFalse(Payday.shouldCheckGmail(semi, today: "2026-10-08", paidDates: []))
        XCTAssertTrue(Payday.shouldCheckGmail(semi, today: "2026-10-13", paidDates: []))
        XCTAssertTrue(Payday.shouldCheckGmail(semi, today: "2026-10-15", paidDates: []))
        XCTAssertTrue(Payday.shouldCheckGmail(semi, today: "2026-10-16", paidDates: []))
        XCTAssertFalse(Payday.shouldCheckGmail(semi, today: "2026-10-15", paidDates: ["2026-10-14"]))
    }
}
