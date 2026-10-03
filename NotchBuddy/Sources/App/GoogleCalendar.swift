import Foundation

// Google Calendar (#116): the next-meeting pill, join links and "do not disturb during meetings".
// Pure logic only (no network, no UI), the same rules as windows/src/core/calendar.ts. The poller
// (events.list every 5 min, timers to the next start/end) feeds `GoogleCalendarLogic.meetings`.

enum JoinKind: String, Equatable, Sendable { case meet, zoom, teams }

struct JoinLink: Equatable, Sendable {
    let kind: JoinKind
    let url: String
}

struct Meeting: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let busy: Bool
    let calendarId: String?
    let join: JoinLink?
    let htmlLink: String?
}

enum MeetingState: Equatable, Sendable {
    case now(Meeting)
    case next(Meeting, inSeconds: TimeInterval)
}

enum GoogleCalendarLogic {
    // MARK: Join links

    private static func classify(_ string: String) -> JoinKind? {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        func matches(_ pattern: String) -> Bool { path.range(of: pattern, options: .regularExpression) != nil }
        if host == "meet.google.com", matches("^/[a-zA-Z]{3}-[a-zA-Z]{4}-[a-zA-Z]{3}/?$") { return .meet }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host.hasSuffix(".zoomgov.com"),
           matches("^/(j|my|wc/join)/") { return .zoom }
        if host == "teams.microsoft.com", path.hasPrefix("/l/meetup-join/") { return .teams }
        if host == "teams.live.com", path.hasPrefix("/meet/") { return .teams }
        return nil
    }

    private static func urls(in text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let plain = text.replacingOccurrences(of: "&amp;", with: "&")  // descriptions can be HTML
        var found: [String] = []
        var rest = plain[...]
        while let range = rest.range(of: "https?://[^\\s<>\"'\\\\)]+", options: [.regularExpression, .caseInsensitive]) {
            var url = String(rest[range])
            while let last = url.last, ".,;:!?]".contains(last) { url.removeLast() }
            found.append(url)
            rest = rest[range.upperBound...]
        }
        return found
    }

    /// Meet / Zoom / Teams link of an event (Google API JSON): conference data, then location, then description.
    static func joinLink(_ event: [String: Any]) -> JoinLink? {
        var candidates: [String] = []
        let entryPoints = (event["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        for p in entryPoints where p["entryPointType"] as? String == "video" {
            if let uri = p["uri"] as? String { candidates.append(uri) }
        }
        if let hangout = event["hangoutLink"] as? String { candidates.append(hangout) }
        candidates += urls(in: event["location"] as? String)
        candidates += urls(in: event["description"] as? String)
        for url in candidates {
            if let kind = classify(url) { return JoinLink(kind: kind, url: url) }
        }
        return nil
    }

    // MARK: Events

    /// "2026-10-03" → local midnight (all-day dates have no zone: they mean the user's day).
    private static func localDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// `dateTime` carries its own UTC offset, so the instant is right in any time zone.
    private static func instant(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string) ?? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: string)
        }()
    }

    /// One API event → Meeting, or nil when it never counts: cancelled, declined by the user,
    /// or without a readable start/end.
    static func meeting(_ event: [String: Any], calendarId: String? = nil) -> Meeting? {
        if event["status"] as? String == "cancelled" { return nil }
        let attendees = event["attendees"] as? [[String: Any]] ?? []
        if attendees.contains(where: { $0["self"] as? Bool == true && $0["responseStatus"] as? String == "declined" }) { return nil }
        let start = event["start"] as? [String: Any] ?? [:]
        let end = event["end"] as? [String: Any] ?? [:]
        let from: Date?, to: Date?, allDay: Bool
        if let s = start["dateTime"] as? String, let e = end["dateTime"] as? String {
            from = instant(s); to = instant(e); allDay = false
        } else if let s = start["date"] as? String, let e = end["date"] as? String {
            from = localDay(s); to = localDay(e); allDay = true
        } else { return nil }
        guard let from, let to, to >= from else { return nil }
        let summary = (event["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Meeting(
            id: event["id"] as? String ?? "\(from.timeIntervalSince1970)-\(summary)",
            title: summary.isEmpty ? L("(No title)") : summary,
            start: from, end: to, allDay: allDay,
            busy: event["transparency"] as? String != "transparent",
            calendarId: calendarId,
            join: joinLink(event),
            htmlLink: event["htmlLink"] as? String)
    }

    static func meetings(_ events: [[String: Any]], calendarId: String? = nil) -> [Meeting] {
        events.compactMap { meeting($0, calendarId: calendarId) }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Keep the chosen calendars; nil = all of them.
    static func filter(_ meetings: [Meeting], calendars enabled: Set<String>?) -> [Meeting] {
        guard let enabled else { return meetings }
        return meetings.filter { $0.calendarId.map(enabled.contains) ?? false }
    }

    /// Timed events only: all-day events are not meetings.
    private static func timed(_ meetings: [Meeting]) -> [Meeting] {
        meetings.filter { !$0.allDay && $0.end > $0.start }
    }

    // MARK: Pill, do not disturb, timers

    /// The meeting in progress (ending soonest), else the next one starting within `horizon`.
    static func pick(_ meetings: [Meeting], now: Date, horizon: TimeInterval = 3600, busyOnly: Bool = true) -> MeetingState? {
        let list = timed(meetings).filter { !busyOnly || $0.busy }
        if let current = list.filter({ $0.start <= now && now < $0.end }).min(by: { $0.end < $1.end }) { return .now(current) }
        if let next = list.filter({ $0.start > now }).min(by: { $0.start < $1.start }) {
            let wait = next.start.timeIntervalSince(now)
            if wait <= horizon { return .next(next, inSeconds: wait) }
        }
        return nil
    }

    /// Minutes rounded up, never 0.
    static func minutes(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / 60).rounded(.up))) }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "Standup in 12 min" / "Now: Standup (until 10:15)".
    static func pillText(_ state: MeetingState) -> String {
        switch state {
        case .now(let m):
            return L("Now: \(m.title) (until \(clock(m.end)))")
        case .next(let m, let seconds):
            let min = minutes(seconds)
            if min < 60 { return L("\(m.title) in \(min) min") }
            let h = min / 60, r = min % 60
            return r == 0 ? L("\(m.title) in \(h) h") : L("\(m.title) in \(h) h \(r) min")
        }
    }

    /// Do not disturb during meetings: until when, or nil. Busy, timed events only (same rule as the
    /// EventKit mode); back-to-back or overlapping meetings are one stretch.
    static func dndUntil(_ meetings: [Meeting], now: Date) -> Date? {
        var until: Date?
        for m in timed(meetings).filter(\.busy).sorted(by: { $0.start < $1.start }) {
            if let u = until {
                if m.start <= u { until = max(u, m.end) }
            } else if m.start <= now && now < m.end {
                until = m.end
            }
        }
        return until
    }

    /// The next moment something changes (heads-up, start or end), for one wake-up timer.
    static func nextWake(_ meetings: [Meeting], now: Date, headsUp: TimeInterval = 300) -> Date? {
        timed(meetings).flatMap { [$0.start.addingTimeInterval(-headsUp), $0.start, $0.end] }
            .filter { $0 > now }.min()
    }

    /// Meetings starting within `headsUp` that were not announced yet.
    static func headsUpDue(_ meetings: [Meeting], now: Date, announced: Set<String>, headsUp: TimeInterval = 300) -> [Meeting] {
        timed(meetings).filter {
            $0.busy && $0.start > now && $0.start.timeIntervalSince(now) <= headsUp && !announced.contains($0.id)
        }
    }
}
