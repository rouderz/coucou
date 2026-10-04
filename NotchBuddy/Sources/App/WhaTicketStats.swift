import AppKit
import os
import UniformTypeIdentifiers

// WhaTicket stats: how many tickets arrived in the queue and how many we accepted, to keep a
// record of the flow of customers. Same behaviour as windows/src-tauri/src/whaticket.rs (the log)
// and windows/src/core/whaticketStats.ts (the numbers).
//
// The log is local only: ~/Library/Application Support/NotchBuddy/whaticket-stats.json, events
// older than a year are dropped, nothing is ever uploaded. It holds ticket ids, queues and times —
// never a customer's name, phone number or message.
//
// It only covers the time the whaticket.com tab was open with the extension: the log is fed by
// the extension's check-ins.
//
//  - "arrived": a ticket id seen in the queue (pending) for the first time.
//  - "accepted": an arrived ticket that moved into my open tickets, by a click in Coucou
//    ("click"), auto-accept ("auto") or anywhere else, e.g. the web app ("web"); `wait` = seconds
//    between the arrival and the accept.
//  - One arrival and one accept per ticket and day at most.
//  - The first snapshot after a gap (the bridge starts over) logs the tickets already waiting
//    with `backlog: true`: they did come in, but while we weren't watching, so their real arrival
//    time is unknown. They count as arrivals (per day, per queue, in the rate) but are left out of
//    the per-hour chart and of the waits.

struct WhaTicketEvent: Codable, Equatable, Sendable {
    /// The ticket id (a UUID or a number).
    var id: String
    /// "arrived" or "accepted".
    var kind: String
    /// Milliseconds since 1970.
    var at: Double
    /// The local day it was logged, "YYYY-MM-DD" (one arrival / accept per ticket and day).
    var day: String
    var queueId: String?
    var queue: String?
    var channel: String?
    /// Already waiting when we started watching: arrival time unknown.
    var backlog: Bool?
    /// accepted: "click", "auto" or "web".
    var how: String?
    /// accepted: seconds since the arrival (nil for a backlog ticket).
    var wait: Int?

    var date: Date { Date(timeIntervalSince1970: at / 1000) }
}

/// The event log and its rules (pure, tested in WhaTicketStatsTests).
struct WhaTicketTracker: Sendable {
    /// What the log keeps of a ticket in the queue.
    struct Seen: Equatable, Sendable {
        let id: String
        let queueId: String?
        let queue: String
        let channel: String?
    }

    nonisolated static let keepDays = 365

    private(set) var events: [WhaTicketEvent] = []
    /// Arrived and not accepted yet: id → its arrival.
    private var open: [String: WhaTicketEvent] = [:]
    private var arrivedOn: Set<String> = []
    private var acceptedOn: Set<String> = []

    init(events: [WhaTicketEvent] = []) {
        self.events = events.filter { $0.kind == "arrived" || $0.kind == "accepted" }.sorted { $0.at < $1.at }
        rebuild()
    }

    private mutating func rebuild() {
        open = [:]
        arrivedOn = []
        acceptedOn = []
        for e in events {
            if e.kind == "arrived" {
                open[e.id] = e
                arrivedOn.insert(e.id + "|" + e.day)
            } else {
                open[e.id] = nil
                acceptedOn.insert(e.id + "|" + e.day)
            }
        }
    }

    private static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }

    /// One snapshot of the queue (`pending`) and my open tickets (`mine`). `backlog`: the first
    /// snapshot after a gap. Returns whether anything was logged.
    mutating func observe(pending: [Seen], mine: [String], backlog: Bool, now: Date, day: String) -> Bool {
        var changed = false
        for t in pending where open[t.id] == nil && !arrivedOn.contains(t.id + "|" + day) {
            let e = WhaTicketEvent(id: t.id, kind: "arrived", at: Self.ms(now), day: day,
                                   queueId: t.queueId, queue: t.queue.isEmpty ? nil : t.queue, channel: t.channel,
                                   backlog: backlog ? true : nil, how: nil, wait: nil)
            events.append(e)
            open[t.id] = e
            arrivedOn.insert(t.id + "|" + day)
            changed = true
        }
        // Moved from the queue into my tickets, by any means: accepted elsewhere (a click or
        // auto-accept in Coucou is logged as soon as the extension confirms it).
        let waiting = Set(pending.map(\.id))
        for id in mine where !waiting.contains(id) {
            if accept(id, how: "web", now: now, day: day) { changed = true }
        }
        return changed
    }

    /// An arrived ticket became mine. Returns whether it was logged.
    mutating func accept(_ id: String, how: String, now: Date, day: String) -> Bool {
        guard let arrival = open.removeValue(forKey: id) else { return false }
        guard acceptedOn.insert(id + "|" + day).inserted else { return false }
        let wait = arrival.backlog == true ? nil : max(0, Int((Self.ms(now) - arrival.at) / 1000))
        events.append(WhaTicketEvent(id: id, kind: "accepted", at: Self.ms(now), day: day,
                                     queueId: arrival.queueId, queue: arrival.queue, channel: arrival.channel,
                                     backlog: nil, how: how, wait: wait))
        return true
    }

    /// Drops what is older than a year. Returns whether anything was dropped.
    mutating func prune(now: Date) -> Bool {
        let cutoff = Self.ms(now) - Double(Self.keepDays) * 86_400_000
        let before = events.count
        events.removeAll { $0.at < cutoff }
        guard events.count != before else { return false }
        rebuild()
        return true
    }

    mutating func reset() {
        events = []
        rebuild()
    }
}

// MARK: - The numbers (pure, tested)

struct WhaTicketSummary: Equatable, Sendable {
    struct Queue: Equatable, Sendable, Identifiable {
        var name: String
        var arrived = 0
        var accepted = 0
        var averageWait: Int?
        var id: String { name }
    }
    struct Hour: Equatable, Sendable {
        var arrived = 0
        var accepted = 0
    }
    struct Day: Equatable, Sendable, Identifiable {
        var day: String
        var arrived = 0
        var accepted = 0
        var id: String { day }
    }

    var arrived = 0
    /// Of which already waiting when we started watching.
    var backlog = 0
    var accepted = 0
    var click = 0
    var auto = 0
    var web = 0
    /// accepted / arrived (0…1), nil with no arrivals.
    var rate: Double?
    /// Seconds.
    var averageWait: Int?
    var medianWait: Int?
    /// Busiest first. A ticket with no queue has an empty name.
    var queues: [Queue] = []
    /// 0…23, local time. Backlog arrivals are left out.
    var hours: [Hour] = Array(repeating: Hour(), count: 24)
    var days: [Day] = []
}

enum WhaTicketStats {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case today, week, month, custom
        var id: String { rawValue }
    }

    /// [from, to) for a period. `custom` goes from the start of `from`'s day to the end of `to`'s day.
    nonisolated static func range(_ period: Period, now: Date, from: Date = .now, to: Date = .now,
                                  calendar: Calendar = .current) -> (from: Date, to: Date) {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        func daysBack(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today }
        switch period {
        case .today: return (today, tomorrow)
        case .week: return (daysBack(6), tomorrow)
        case .month: return (daysBack(29), tomorrow)
        case .custom:
            let a = calendar.startOfDay(for: min(from, to))
            let b = calendar.startOfDay(for: max(from, to))
            return (a, calendar.date(byAdding: .day, value: 1, to: b) ?? b)
        }
    }

    nonisolated static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : Int((Double(s[mid - 1] + s[mid]) / 2).rounded())
    }

    nonisolated static func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    nonisolated static func queueName(_ e: WhaTicketEvent) -> String {
        e.queue ?? e.queueId ?? ""
    }

    nonisolated static func summary(_ events: [WhaTicketEvent], from: Date, to: Date,
                                    calendar: Calendar = .current) -> WhaTicketSummary {
        var s = WhaTicketSummary()
        let a = from.timeIntervalSince1970 * 1000, b = to.timeIntervalSince1970 * 1000
        var waits: [Int] = []
        var queues: [String: (row: WhaTicketSummary.Queue, waits: [Int])] = [:]
        var days: [String: WhaTicketSummary.Day] = [:]
        for e in events where e.at >= a && e.at < b {
            let name = queueName(e)
            var q = queues[name] ?? (row: WhaTicketSummary.Queue(name: name), waits: [Int]())
            let date = e.date
            let hour = calendar.component(.hour, from: date)
            let day = TimeTracking.dayKey(date, calendar: calendar)
            var d = days[day] ?? WhaTicketSummary.Day(day: day)
            if e.kind == "arrived" {
                s.arrived += 1
                q.row.arrived += 1
                d.arrived += 1
                if e.backlog == true { s.backlog += 1 } else if (0..<24).contains(hour) { s.hours[hour].arrived += 1 }
            } else if e.kind == "accepted" {
                s.accepted += 1
                q.row.accepted += 1
                d.accepted += 1
                if (0..<24).contains(hour) { s.hours[hour].accepted += 1 }
                switch e.how {
                case "click": s.click += 1
                case "auto": s.auto += 1
                default: s.web += 1
                }
                if let w = e.wait {
                    waits.append(w)
                    q.waits.append(w)
                }
            }
            queues[name] = q
            days[day] = d
        }
        s.rate = s.arrived > 0 ? Double(s.accepted) / Double(s.arrived) : nil
        s.averageWait = average(waits)
        s.medianWait = median(waits)
        s.queues = queues.values.map { v in
            var row = v.row
            row.averageWait = average(v.waits)
            return row
        }
        .sorted { ($0.arrived, $0.accepted, $1.name) > ($1.arrived, $1.accepted, $0.name) }
        // Every day of the range, empty ones included (at most ~13 months).
        var day = calendar.startOfDay(for: from)
        var count = 0
        while day < to && count < 400 {
            let key = TimeTracking.dayKey(day, calendar: calendar)
            s.days.append(days[key] ?? WhaTicketSummary.Day(day: key))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? to
            count += 1
        }
        return s
    }

    /// Today's arrivals, accepts and auto-accepts, for the card. Events are in time order, so
    /// only today's tail is read.
    nonisolated static func today(_ events: [WhaTicketEvent], now: Date = .now,
                                  calendar: Calendar = .current) -> (arrived: Int, accepted: Int, auto: Int) {
        let start = calendar.startOfDay(for: now).timeIntervalSince1970 * 1000
        var arrived = 0, accepted = 0, auto = 0
        for e in events.reversed() {
            guard e.at >= start else { break }
            if e.kind == "arrived" { arrived += 1 } else if e.kind == "accepted" {
                accepted += 1
                if e.how == "auto" { auto += 1 }
            }
        }
        return (arrived, accepted, auto)
    }

    /// One row per event of the range: date, time, event, how, queue, wait seconds, ticket.
    /// `how` is "backlog" for a ticket already waiting when we started watching.
    nonisolated static func csv(_ events: [WhaTicketEvent], from: Date, to: Date,
                                calendar: Calendar = .current) -> String {
        let a = from.timeIntervalSince1970 * 1000, b = to.timeIntervalSince1970 * 1000
        var out = ["date,time,event,how,queue,wait_seconds,ticket"]
        for e in events where e.at >= a && e.at < b {
            let date = e.date
            let c = calendar.dateComponents([.hour, .minute, .second], from: date)
            let time = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            let how = e.kind == "arrived" ? (e.backlog == true ? "backlog" : "") : (e.how ?? "")
            out.append([TimeTracking.dayKey(date, calendar: calendar), time, e.kind, how, queueName(e),
                        e.wait.map(String.init) ?? "", e.id].map(TimeTracking.csvCell).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// "45 s", "3 min", "1 h 05 min".
    nonisolated static func duration(_ seconds: Int?) -> String {
        guard let s = seconds else { return "—" }
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60)
    }
}

// MARK: - The log on disk

@MainActor
final class WhaTicketLog: ObservableObject {
    static let shared = WhaTicketLog()

    @Published private(set) var events: [WhaTicketEvent] = []
    private var tracker: WhaTicketTracker
    private var saving: Task<Void, Never>?
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "whaticket")

    /// ~/Library/Application Support/NotchBuddy/whaticket-stats.json
    nonisolated static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy/whaticket-stats.json")
    }

    private struct File: Codable {
        var version = 1
        var events: [WhaTicketEvent]
    }

    private init() {
        var loaded: [WhaTicketEvent] = []
        if let data = try? Data(contentsOf: Self.url) {
            if let file = try? JSONDecoder().decode(File.self, from: data) {
                loaded = file.events
            } else {
                // Unreadable: keep it aside rather than overwrite it.
                let aside = Self.url.deletingPathExtension().appendingPathExtension("unreadable.json")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: Self.url, to: aside)
            }
        }
        tracker = WhaTicketTracker(events: loaded)
        if tracker.prune(now: .now) { scheduleSave() }
        events = tracker.events
    }

    private static func day(_ date: Date) -> String { TimeTracking.dayKey(date) }

    /// One snapshot from the extension.
    func observe(pending: [WhaTicketTicket], mine: [WhaTicketTicket], backlog: Bool) {
        let seen = pending.map { WhaTicketTracker.Seen(id: $0.id, queueId: $0.queueId, queue: $0.queue, channel: $0.channel) }
        let now = Date.now
        if tracker.observe(pending: seen, mine: mine.map(\.id), backlog: backlog, now: now, day: Self.day(now)) {
            changed()
        }
    }

    /// The extension confirmed an accept we sent ("click" or "auto").
    func accepted(_ id: String, how: String) {
        let now = Date.now
        if tracker.accept(id, how: how, now: now, day: Self.day(now)) { changed() }
    }

    func reset() {
        tracker.reset()
        events = []
        saving?.cancel()
        saving = nil
        save()
        log.info("whaticket stats reset")
    }

    private func changed() {
        events = tracker.events
        scheduleSave()
    }

    /// Written a few seconds after a change, once for a burst of changes — never on a check-in
    /// where nothing happened.
    private func scheduleSave() {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.saving = nil
            self.save()
        }
    }

    private func save() {
        _ = tracker.prune(now: .now)
        events = tracker.events
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(File(events: tracker.events)).write(to: Self.url, options: .atomic)
        } catch {
            log.error("whaticket stats not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Settings → WhaTicket → Export CSV: asks where to save it.
    func exportCSV(from: Date, to: Date) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "whaticket-\(TimeTracking.dayKey(from)).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let text = WhaTicketStats.csv(events, from: from, to: to)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            log.error("whaticket CSV not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
