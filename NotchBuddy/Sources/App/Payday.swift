import Foundation

// Payday (#110): when the next pay is, and whether the last one arrived.
// Dates are plain "YYYY-MM-DD" days (no time zones). Gusto pays on the business day before a
// weekend payday; holidays are not known here, so a holiday list can be passed in.
// Mirrors windows/src/core/payday.ts and paydayMail.ts.

enum PaySchedule: Equatable, Sendable {
    case semimonthly(Int, Int)   // 1–31; 31 = the last day of the month
    case monthly(Int)
    case biweekly(anchor: String) // any known payday
    case weekly(anchor: String)
}

enum PaydayStatus: Equatable, Sendable {
    case paid(date: String)
    case dueToday
    case late(expected: String, daysLate: Int)
    case upcoming(date: String, inDays: Int)
}

enum Payday {
    /// After this many days without a pay mail the pill stops saying "late" and looks ahead again.
    static let lateDays = 5

    /// The Gmail search the Gusto preset uses.
    static let gustoQuery = "from:gusto.com (paystub OR paid) newer_than:7d"

    // MARK: civil dates <-> day numbers (proleptic Gregorian, days since 1970-01-01)

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func parts(_ date: String) -> (Int, Int, Int) {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? (p[0], p[1], p[2]) : (1970, 1, 1)
    }

    static func toDays(_ date: String) -> Int {
        let (y, m, d) = parts(date)
        let yy = m <= 2 ? y - 1 : y
        let era = floorDiv(yy, 400)
        let yoe = yy - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func fromDays(_ days: Int) -> String {
        let z = days + 719468
        let era = floorDiv(z, 146097)
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// 0 = Sunday … 6 = Saturday.
    private static func weekday(_ days: Int) -> Int {
        ((days + 4) % 7 + 7) % 7
    }

    private static func ymd(_ y: Int, _ m: Int, _ d: Int) -> Int {
        toDays(String(format: "%04d-%02d-%02d", y, m, d))
    }

    private static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        (m == 12 ? ymd(y + 1, 1, 1) : ymd(y, m + 1, 1)) - ymd(y, m, 1)
    }

    /// Moves a weekend or holiday payday back to the previous business day.
    private static func shift(_ days: Int, _ holidays: Set<Int>) -> Int {
        var d = days
        while weekday(d) == 0 || weekday(d) == 6 || holidays.contains(d) { d -= 1 }
        return d
    }

    /// Every adjusted payday between two day numbers (inclusive), in order.
    private static func paydaysBetween(_ schedule: PaySchedule, _ from: Int, _ to: Int, _ holidays: Set<Int>) -> [Int] {
        var out = Set<Int>()
        switch schedule {
        case .biweekly(let anchorDate), .weekly(let anchorDate):
            var step = 14
            if case .weekly = schedule { step = 7 }
            let anchor = toDays(anchorDate)
            // Start a few steps early: the shift can move a payday before `from`.
            var d = anchor + floorDiv(from - 7 - anchor, step) * step
            while d <= to + 7 {
                let adjusted = shift(d, holidays)
                if adjusted >= from && adjusted <= to { out.insert(adjusted) }
                d += step
            }
        case .semimonthly, .monthly:
            var days: [Int] = []
            if case .monthly(let day) = schedule { days = [day] }
            if case .semimonthly(let a, let b) = schedule { days = [a, b] }
            let (fy, fm) = { () -> (Int, Int) in let p = parts(fromDays(from)); return (p.0, p.1) }()
            var y = fy
            var m = fm - 1
            if m < 1 { m = 12; y -= 1 }
            for _ in 0..<40 {
                for day in days {
                    let nominal = ymd(y, m, min(day, daysInMonth(y, m)))
                    let adjusted = shift(nominal, holidays)
                    if adjusted >= from && adjusted <= to { out.insert(adjusted) }
                }
                m += 1
                if m > 12 { m = 1; y += 1 }
                if ymd(y, m, 1) > to + 31 { break }
            }
        }
        return out.sorted()
    }

    /// The first payday on or after `from`.
    static func nextPayday(_ schedule: PaySchedule, from: String, holidays: [String] = []) -> String {
        let start = toDays(from)
        let all = paydaysBetween(schedule, start, start + 100, Set(holidays.map(toDays)))
        return fromDays(all.first ?? start)
    }

    /// The last payday on or before `from`.
    static func previousPayday(_ schedule: PaySchedule, from: String, holidays: [String] = []) -> String {
        let end = toDays(from)
        let all = paydaysBetween(schedule, end - 100, end, Set(holidays.map(toDays)))
        return fromDays(all.last ?? end)
    }

    /// What the pill says. `paidDates` are the days Gusto's mails arrived (from the Gmail search).
    /// A mail up to 2 days before the payday counts for it (pay stubs are often sent ahead).
    static func status(_ schedule: PaySchedule, today: String, paidDates: [String], holidays: [String] = []) -> PaydayStatus {
        let now = toDays(today)
        let last = toDays(previousPayday(schedule, from: today, holidays: holidays))
        let mail = paidDates.map(toDays).filter { $0 >= last - 2 && $0 <= now }.max()
        if let mail, now - last <= 3 { return .paid(date: fromDays(mail)) }
        if mail == nil && now == last { return .dueToday }
        if mail == nil && now > last && now - last <= lateDays { return .late(expected: fromDays(last), daysLate: now - last) }
        let next = nextPayday(schedule, from: fromDays(now + 1), holidays: holidays)
        return .upcoming(date: next, inDays: toDays(next) - now)
    }

    // MARK: Gmail matcher
    // Only the sender, subject, snippet and date are looked at. Amounts are optional, only read when
    // the mail states the net pay, kept in memory and never logged or stored.

    private static let payWords = try! NSRegularExpression(
        pattern: "paystub|pay stub|pay statement|you['’]ve been paid|you have been paid|you were paid|payday|direct deposit|payment (is )?(sent|on its way)",
        options: .caseInsensitive)
    private static let notPaid = try! NSRegularExpression(
        pattern: "reminder|upcoming|will be paid|scheduled|is due|timesheet|approve|submit|review your|action required|verify|about to",
        options: .caseInsensitive)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// True when a mail from Gusto says the user was paid.
    static func isGustoPayMail(from: String, subject: String, snippet: String) -> Bool {
        guard from.localizedCaseInsensitiveContains("gusto") else { return false }
        if matches(notPaid, subject) { return false }
        return matches(payWords, subject) || (matches(payWords, snippet) && !matches(notPaid, snippet))
    }

    /// The local calendar day of a Gmail message's date.
    static func day(of date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    enum Source { case gusto, bank }

    /// Days with a pay mail, newest first, at most 6. `.bank` mails come from the user's own bank
    /// search, so the search itself is the filter; Gusto mails are checked by `isGustoPayMail`.
    static func paidDates(from mails: [GmailMessage], source: Source, calendar: Calendar = .current) -> [String] {
        var days = Set<String>()
        for m in mails {
            guard let date = m.date else { continue }
            if source == .gusto && !isGustoPayMail(from: m.from, subject: m.subject, snippet: m.snippet) { continue }
            days.insert(day(of: date, calendar: calendar))
        }
        return Array(days.sorted(by: >).prefix(6))
    }

    /// The net amount in cents, only when the mail states it. Never guessed from other figures.
    static func netAmountCents(_ text: String) -> Int? {
        guard let re = try? NSRegularExpression(
            pattern: "(?:net (?:pay|amount|wages)|take[- ]home(?: pay)?|deposit(?:ed)? of)\\D{0,20}\\$\\s?(\\d{1,3}(?:,\\d{3})*|\\d+)(?:\\.(\\d{2}))?",
            options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(m.range(at: 1), in: text),
              let dollars = Int(text[whole].replacingOccurrences(of: ",", with: ""))
        else { return nil }
        var cents = 0
        if let r = Range(m.range(at: 2), in: text) { cents = Int(text[r]) ?? 0 }
        return dollars * 100 + cents
    }

    /// Whether Gmail is worth asking right now: from two days before a payday until the pill would
    /// stop saying "late", and not once the payment is already seen.
    static func shouldCheckGmail(_ schedule: PaySchedule, today: String, paidDates: [String], holidays: [String] = []) -> Bool {
        switch status(schedule, today: today, paidDates: paidDates, holidays: holidays) {
        case .paid: return false
        case .upcoming(_, let inDays): return inDays <= 2
        case .dueToday, .late: return true
        }
    }
}
