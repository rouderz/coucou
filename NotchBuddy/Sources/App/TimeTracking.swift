import Foundation

// MARK: - Time per Linear issue (#114)
//
// Turns the session events the hook already sees (start / prompt / activity / stop / idle)
// into active time per issue per day. Pure value types and functions, no UI and no network:
// the data stays in a JSON file in Application Support and is never uploaded. Days are
// LOCAL days (the `calendar` argument, `.current` by default).
//
// Rules (same as windows/src/core/timetrack.ts):
//  - A session is "working" from a start / prompt / activity event until its next event;
//    a stop or idle event closes the span at its own time.
//  - A gap longer than the idle threshold is NOT counted (the user walked away, or the
//    session was abandoned), unless the gap ends with a stop: that turn really ran.
//  - A span still open at the end counts only up to `now`, while `now` is within the idle
//    threshold of the last event.
//  - A span belongs to the issue linked to the session (the earlier event's link, else the
//    later one's). Without an issue it goes to "repo @ branch".
//  - Spans of different sessions on the same issue are merged (union), so two parallel
//    sessions never count the same minute twice.
//  - A span crossing local midnight is split between the two days.

struct TimeIssue: Equatable, Hashable, Codable, Sendable {
    let identifier: String      // "SHO-475"
    let title: String
}

struct TimeEvent: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case start, prompt, activity, stop, idle }

    let session: String
    let kind: Kind
    let at: Date
    var issue: TimeIssue?
    var repo: String?
    var branch: String?
}

/// Time spent on one issue (or one repo/branch) on one day.
struct TimeRow: Equatable, Sendable {
    let day: String             // YYYY-MM-DD, local
    let key: String             // "SHO-475" or "repo @ branch"
    var issue: TimeIssue?
    var repo: String?
    var branch: String?
    var seconds: TimeInterval
}

/// A manual +/- on a day and key (also an entry for work outside Claude Code).
struct TimeAdjustment: Equatable, Codable, Sendable {
    let day: String
    let key: String
    var deltaSeconds: TimeInterval
    var title: String?
}

struct TimePeriodDay: Equatable, Sendable {
    let day: String
    let rows: [TimeRow]
    var seconds: TimeInterval { rows.reduce(0) { $0 + $1.seconds } }
    /// One line for the timesheet: "SHO-475: PDP redesign; SHO-480: Cart bug".
    let description: String
}

enum TimeTracking {
    static let defaultIdle: TimeInterval = 10 * 60
    static let keepDays = 180
    private static let activityMerge: TimeInterval = 30

    struct Span: Equatable, Sendable {
        let key: String
        let start: Date
        let end: Date
        let issue: TimeIssue?
        let repo: String?
        let branch: String?
    }

    // MARK: Spans

    nonisolated static func key(issue: TimeIssue?, repo: String?, branch: String?) -> String {
        if let id = issue?.identifier, !id.isEmpty { return id }
        let r = repo?.trimmingCharacters(in: .whitespaces) ?? ""
        let b = branch?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = r.isEmpty ? "(no repo)" : r
        return b.isEmpty ? name : "\(name) @ \(b)"
    }

    /// The working spans of every session, before merging.
    nonisolated static func spans(from events: [TimeEvent], idle: TimeInterval = defaultIdle, now: Date? = nil) -> [Span] {
        var bySession: [String: [(Int, TimeEvent)]] = [:]
        for (i, e) in events.enumerated() { bySession[e.session, default: []].append((i, e)) }
        var out: [Span] = []
        func push(_ from: TimeEvent, _ to: Date, _ next: TimeEvent?) {
            guard to > from.at else { return }
            let src = from.issue != nil ? from : (next?.issue != nil ? next! : from)
            out.append(Span(key: key(issue: src.issue, repo: src.repo ?? from.repo ?? next?.repo,
                                     branch: src.branch ?? from.branch ?? next?.branch),
                            start: from.at, end: to, issue: src.issue,
                            repo: src.repo ?? from.repo ?? next?.repo,
                            branch: src.branch ?? from.branch ?? next?.branch))
        }
        for list in bySession.values {
            let sorted = list.sorted { $0.1.at != $1.1.at ? $0.1.at < $1.1.at : $0.0 < $1.0 }.map(\.1)
            var open: TimeEvent?
            for e in sorted {
                if let o = open, e.at.timeIntervalSince(o.at) <= idle || e.kind == .stop { push(o, e.at, e) }
                open = (e.kind == .stop || e.kind == .idle) ? nil : e
            }
            if let o = open, let now, now.timeIntervalSince(o.at) <= idle { push(o, now, nil) }
        }
        return out
    }

    // MARK: Days

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private nonisolated static func nextMidnight(after date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86_400)
    }

    /// Union of overlapping or touching spans of one key, split at local midnight, summed per day.
    nonisolated static func aggregate(_ events: [TimeEvent], idle: TimeInterval = defaultIdle, now: Date? = nil,
                                      calendar: Calendar = .current) -> [TimeRow] {
        var byKey: [String: [Span]] = [:]
        for s in spans(from: events, idle: idle, now: now) { byKey[s.key, default: []].append(s) }
        var rows: [String: TimeRow] = [:]
        for (key, list) in byKey {
            let sorted = list.sorted { $0.start < $1.start }
            var merged: [(start: Date, end: Date)] = []
            for s in sorted {
                if let last = merged.last, s.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, s.end)
                } else {
                    merged.append((s.start, s.end))
                }
            }
            let meta = sorted.reduce(sorted[0]) { $1.start >= $0.start ? $1 : $0 }
            for m in merged {
                var from = m.start
                while from < m.end {
                    let to = min(m.end, nextMidnight(after: from, calendar: calendar))
                    let day = dayKey(from, calendar: calendar)
                    let id = "\(day)\u{0}\(key)"
                    var row = rows[id] ?? TimeRow(day: day, key: key, issue: meta.issue, repo: meta.repo,
                                                  branch: meta.branch, seconds: 0)
                    row.seconds += to.timeIntervalSince(from)
                    rows[id] = row
                    from = to
                }
            }
        }
        return sortRows(Array(rows.values))
    }

    private nonisolated static func sortRows(_ rows: [TimeRow]) -> [TimeRow] {
        rows.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            return $0.key < $1.key
        }
    }

    /// Manual edits on top of the tracked time. Never below zero; empty rows disappear.
    nonisolated static func apply(_ adjustments: [TimeAdjustment], to rows: [TimeRow]) -> [TimeRow] {
        var map: [String: TimeRow] = [:]
        for r in rows { map["\(r.day)\u{0}\(r.key)"] = r }
        for a in adjustments {
            let id = "\(a.day)\u{0}\(a.key)"
            var row = map[id] ?? TimeRow(
                day: a.day, key: a.key,
                issue: a.key.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil
                    ? TimeIssue(identifier: a.key, title: a.title ?? "") : nil,
                seconds: 0)
            row.seconds = max(0, row.seconds + a.deltaSeconds)
            map[id] = row
        }
        return sortRows(map.values.filter { $0.seconds > 0 })
    }

    // MARK: Periods

    /// The first or second half of the month a date is in, as inclusive YYYY-MM-DD bounds.
    nonisolated static func halfMonth(of date: Date, calendar: Calendar = .current) -> (from: String, to: String) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 1
        if (c.day ?? 1) <= 15 { return (String(format: "%04d-%02d-01", y, m), String(format: "%04d-%02d-15", y, m)) }
        let last = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        return (String(format: "%04d-%02d-16", y, m), String(format: "%04d-%02d-%02d", y, m, last))
    }

    nonisolated static func describe(_ rows: [TimeRow]) -> String {
        rows.sorted { $0.seconds > $1.seconds }.map { r -> String in
            guard let issue = r.issue else { return r.key }
            return issue.title.isEmpty ? issue.identifier : "\(issue.identifier): \(issue.title)"
        }.joined(separator: "; ")
    }

    /// Rows from `from` to `to` (inclusive), grouped by day; days without time are left out.
    nonisolated static func groupPeriod(_ rows: [TimeRow], from: String, to: String) -> [TimePeriodDay] {
        var days: [String: [TimeRow]] = [:]
        for r in rows where r.day >= from && r.day <= to && r.seconds > 0 { days[r.day, default: []].append(r) }
        return days.keys.sorted().map { day in
            let list = days[day]!.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.key < $1.key }
            return TimePeriodDay(day: day, rows: list, description: describe(list))
        }
    }

    // MARK: Export (rows only; nothing is written anywhere)

    /// Rounds to a step in minutes (0 = no rounding).
    nonisolated static func roundSeconds(_ seconds: TimeInterval, stepMinutes: Int = 0) -> TimeInterval {
        guard stepMinutes > 0 else { return seconds }
        let step = TimeInterval(stepMinutes * 60)
        return (seconds / step).rounded() * step
    }

    nonisolated static func hours(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds / 3600) }

    /// Plain text, one line per day, then the total.
    nonisolated static func text(_ days: [TimePeriodDay], roundMinutes: Int = 0) -> String {
        var lines: [String] = []
        var total: TimeInterval = 0
        for d in days {
            let s = d.rows.reduce(0) { $0 + roundSeconds($1.seconds, stepMinutes: roundMinutes) }
            total += s
            lines.append("\(d.day)  \(hours(s)) h  \(d.description)")
        }
        if !days.isEmpty { lines.append("Total  \(hours(total)) h") }
        return lines.joined(separator: "\n")
    }

    /// A CSV cell (RFC 4180). Titles come from Linear, so a leading = + - @ is defused for spreadsheets.
    nonisolated static func csvCell(_ value: String) -> String {
        var s = value
        if let f = s.first, "=+-@\t\r".contains(f) { s = "'" + s }
        return s.contains(where: { "\",\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// "issue": one row per day and issue (Date, Issue, Title, Repo, Branch, Hours);
    /// otherwise one row per day (Date, Hours, Description).
    nonisolated static func csv(_ days: [TimePeriodDay], perIssue: Bool = true, roundMinutes: Int = 0) -> String {
        var out: [String]
        if perIssue {
            out = ["Date,Issue,Title,Repo,Branch,Hours"]
            for d in days {
                for r in d.rows {
                    out.append([d.day, r.issue?.identifier ?? "", r.issue?.title ?? "", r.repo ?? "", r.branch ?? "",
                                hours(roundSeconds(r.seconds, stepMinutes: roundMinutes))].map(csvCell).joined(separator: ","))
                }
            }
        } else {
            out = ["Date,Hours,Description"]
            for d in days {
                let s = d.rows.reduce(0) { $0 + roundSeconds($1.seconds, stepMinutes: roundMinutes) }
                out.append([d.day, hours(s), d.description].map(csvCell).joined(separator: ","))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - Local store

/// What is kept on disk: the raw events (so the idle threshold can change later) and manual edits.
struct TimeStore: Equatable, Codable, Sendable {
    var version = 1
    var events: [TimeEvent] = []
    var adjustments: [TimeAdjustment] = []

    /// Adds an event. A run of "activity" events of a session less than 30 s apart is kept as one
    /// event moved forward, so tool-heavy sessions don't grow the file while the covered time stays
    /// the same. Events older than `TimeTracking.keepDays` are dropped.
    mutating func record(_ event: TimeEvent, now: Date? = nil) {
        let now = now ?? event.at
        let cutoff = now.addingTimeInterval(-Double(TimeTracking.keepDays) * 86_400)
        events.removeAll { $0.at < cutoff }
        if event.kind == .activity, let i = events.lastIndex(where: { $0.session == event.session }) {
            let prev = events[i]
            if prev.kind == .activity, event.at >= prev.at, event.at.timeIntervalSince(prev.at) < 30,
               TimeTracking.key(issue: prev.issue, repo: prev.repo, branch: prev.branch)
                == TimeTracking.key(issue: event.issue, repo: event.repo, branch: event.branch) {
                events[i] = event
                return
            }
        }
        events.append(event)
    }

    /// Adds a manual edit; edits of the same day and key are summed, and a zero sum is removed.
    mutating func adjust(_ adj: TimeAdjustment) {
        if let i = adjustments.firstIndex(where: { $0.day == adj.day && $0.key == adj.key }) {
            adjustments[i].deltaSeconds += adj.deltaSeconds
            if let t = adj.title { adjustments[i].title = t }
        } else {
            adjustments.append(adj)
        }
        adjustments.removeAll { $0.deltaSeconds == 0 }
    }

    /// Everything the views and exports need.
    func rows(idle: TimeInterval = TimeTracking.defaultIdle, now: Date? = nil, calendar: Calendar = .current) -> [TimeRow] {
        TimeTracking.apply(adjustments, to: TimeTracking.aggregate(events, idle: idle, now: now, calendar: calendar))
    }

    // MARK: File

    /// ~/Library/Application Support/NotchBuddy/time-tracking.json
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy/time-tracking.json")
    }

    /// A missing or unreadable file gives an empty store.
    static func load(from url: URL = defaultURL) -> TimeStore {
        guard let data = try? Data(contentsOf: url) else { return TimeStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(TimeStore.self, from: data)) ?? TimeStore()
    }

    func save(to url: URL = TimeStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
