import Foundation
import os

// Focus timer (#119): work blocks led by Mochi.
// FocusTimerState is a pure value type with no clock and no timer (mirrors windows/src/core/focus.ts).
// FocusTimer (below) owns the single one-shot Timer, which only exists while a phase is running,
// and applies the Do not disturb writes a step asks for.
//
// Phases: idle -> focus -> break | longBreak -> idle. A focus block that runs out counts as done and
// the break starts by itself; when a break ends we go back to idle. A skipped block is not counted.
// DND: a focus block turns it on until the block's end; the value found at the start is put back at
// the end (or on pause / stop / skip) unless the user changed DND meanwhile. Breaks never hold DND.

enum FocusPhase: String, Sendable, Equatable {
    case idle, focus, shortBreak, longBreak
}

struct FocusConfig: Sendable, Equatable {
    var focusMinutes = 25
    var breakMinutes = 5
    var longBreakMinutes = 15
    /// A long break replaces the break after this many focus blocks.
    var blocksBeforeLong = 4

    /// Whole minutes >= 1.
    func sanitized() -> FocusConfig {
        FocusConfig(focusMinutes: max(1, focusMinutes), breakMinutes: max(1, breakMinutes),
                    longBreakMinutes: max(1, longBreakMinutes), blocksBeforeLong: max(1, blocksBeforeLong))
    }
}

/// What a block did to Do not disturb, so its end can undo it.
struct FocusDndLease: Sendable, Equatable {
    /// DND found when the block started (nil = off).
    var saved: Date?
    /// The value we wrote, nil when we changed nothing.
    var applied: Date?
}

enum FocusEvent: Sendable, Equatable {
    case focusStarted, focusDone, breakDone, paused, resumed, stopped
}

/// The result of a transition. `dnd` is nil when DND must stay as it is, `.some(nil)` for "turn off",
/// `.some(date)` for "on until".
struct FocusStep: Sendable, Equatable {
    var state: FocusTimerState
    var dnd: Date??
    var event: FocusEvent?

    init(_ state: FocusTimerState, dnd: Date?? = nil, event: FocusEvent? = nil) {
        self.state = state
        self.dnd = dnd
        self.event = event
    }
}

struct FocusTimerState: Sendable, Equatable {
    var config: FocusConfig
    var phase: FocusPhase = .idle
    var paused = false
    /// When the running phase ends; nil when idle or paused.
    var endsAt: Date?
    /// Time left while paused.
    var pausedRemaining: TimeInterval?
    /// Length of the current phase, for the ring.
    var duration: TimeInterval = 0
    /// Focus blocks finished since the last long break.
    var cycle = 0
    /// Focus blocks finished today, and the day they belong to.
    var blocksToday = 0
    var day: DateComponents
    var lease: FocusDndLease?

    init(now: Date = .now, config: FocusConfig = FocusConfig(), calendar: Calendar = .current) {
        self.config = config.sanitized()
        self.day = calendar.dateComponents([.year, .month, .day], from: now)
    }

    var isRunning: Bool { phase != .idle && !paused }

    func remaining(at now: Date) -> TimeInterval {
        if phase == .idle { return 0 }
        if paused { return pausedRemaining ?? 0 }
        return max(0, (endsAt ?? now).timeIntervalSince(now))
    }

    /// 0...1 elapsed, for the ring around Mochi.
    func progress(at now: Date) -> Double {
        guard phase != .idle, duration > 0 else { return 0 }
        return min(1, max(0, (duration - remaining(at: now)) / duration))
    }

    /// Seconds until the next wake-up: nil unless a phase is running (so no timer otherwise).
    func nextWake(at now: Date) -> TimeInterval? {
        guard isRunning, let endsAt else { return nil }
        return max(0, endsAt.timeIntervalSince(now))
    }

    /// "24:59": rounded up, so it never reads 00:00 while running.
    static func format(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Transitions

    private mutating func rollDay(_ now: Date, _ calendar: Calendar) {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        if today != day { day = today; blocksToday = 0 }
    }

    /// Starts a focus block (only from idle). `minutes` overrides the configured length for this block.
    func start(now: Date, currentDnd: Date?, minutes: Int? = nil, calendar: Calendar = .current) -> FocusStep {
        var s = self
        s.rollDay(now, calendar)
        guard s.phase == .idle else { return FocusStep(s) }
        var step = s.begin(.focus, now: now, currentDnd: currentDnd, minutes: minutes.map { max(1, $0) })
        step.event = .focusStarted
        return step
    }

    /// Call when the wake-up fires (does nothing before the end).
    func tick(now: Date, currentDnd: Date?, calendar: Calendar = .current) -> FocusStep {
        var s = self
        s.rollDay(now, calendar)
        guard s.isRunning, let endsAt = s.endsAt, now >= endsAt else { return FocusStep(s) }
        if s.phase == .focus { return s.endFocus(now: now, currentDnd: currentDnd, counted: true) }
        return FocusStep(s.idled(), event: .breakDone)
    }

    /// Focus -> break (block not counted), break -> idle.
    func skip(now: Date, currentDnd: Date?, calendar: Calendar = .current) -> FocusStep {
        var s = self
        s.rollDay(now, calendar)
        switch s.phase {
        case .idle: return FocusStep(s)
        case .focus: return s.endFocus(now: now, currentDnd: currentDnd, counted: false)
        case .shortBreak, .longBreak: return FocusStep(s.idled(), event: .breakDone)
        }
    }

    /// Stops everything; the cycle starts over. Puts DND back.
    func stop(now: Date, currentDnd: Date?, calendar: Calendar = .current) -> FocusStep {
        var s = self
        s.rollDay(now, calendar)
        guard s.phase != .idle else { return FocusStep(s) }
        let restore = FocusTimerState.release(now: now, current: currentDnd, lease: s.lease)
        var idle = s.idled()
        idle.cycle = 0
        return FocusStep(idle, dnd: restore, event: .stopped)
    }

    /// Pausing releases DND: a paused block shouldn't keep it on with no end.
    func pause(now: Date, currentDnd: Date?, calendar: Calendar = .current) -> FocusStep {
        var s = self
        s.rollDay(now, calendar)
        guard s.isRunning else { return FocusStep(s) }
        let left = s.remaining(at: now)
        let restore = s.phase == .focus ? FocusTimerState.release(now: now, current: currentDnd, lease: s.lease) : nil
        s.paused = true
        s.endsAt = nil
        s.pausedRemaining = left
        s.lease = nil
        return FocusStep(s, dnd: restore, event: .paused)
    }

    func resume(now: Date, currentDnd: Date?, calendar: Calendar = .current) -> FocusStep {
        var s = self
        s.rollDay(now, calendar)
        guard s.phase != .idle, s.paused else { return FocusStep(s) }
        let end = now.addingTimeInterval(s.pausedRemaining ?? 0)
        s.paused = false
        s.endsAt = end
        s.pausedRemaining = nil
        guard s.phase == .focus else { return FocusStep(s, event: .resumed) }
        let (lease, write) = FocusTimerState.acquire(now: now, current: currentDnd, until: end)
        s.lease = lease
        return FocusStep(s, dnd: write, event: .resumed)
    }

    // MARK: Internals

    private func idled() -> FocusTimerState {
        var s = self
        s.phase = .idle
        s.paused = false
        s.endsAt = nil
        s.pausedRemaining = nil
        s.duration = 0
        s.lease = nil
        return s
    }

    private func begin(_ phase: FocusPhase, now: Date, currentDnd: Date?, minutes: Int? = nil) -> FocusStep {
        var s = self
        let mins = minutes ?? (phase == .focus ? config.focusMinutes
                              : phase == .shortBreak ? config.breakMinutes : config.longBreakMinutes)
        s.phase = phase
        s.paused = false
        s.duration = TimeInterval(mins * 60)
        s.endsAt = now.addingTimeInterval(s.duration)
        s.pausedRemaining = nil
        s.lease = nil
        guard phase == .focus, let end = s.endsAt else { return FocusStep(s) }
        let (lease, write) = FocusTimerState.acquire(now: now, current: currentDnd, until: end)
        s.lease = lease
        return FocusStep(s, dnd: write)
    }

    private func endFocus(now: Date, currentDnd: Date?, counted: Bool) -> FocusStep {
        let restore = FocusTimerState.release(now: now, current: currentDnd, lease: lease)
        var s = self
        let newCycle = cycle + (counted ? 1 : 0)
        let long = counted && newCycle >= config.blocksBeforeLong
        s.cycle = long ? 0 : newCycle
        if counted { s.blocksToday += 1 }
        var step = s.begin(long ? .longBreak : .shortBreak, now: now, currentDnd: currentDnd)
        step.dnd = restore
        step.event = counted ? .focusDone : nil
        return step
    }

    /// Returns the lease and the DND write (nil = leave as is).
    private static func acquire(now: Date, current: Date?, until: Date) -> (FocusDndLease, Date??) {
        let saved = (current.map { $0 > now } ?? false) ? current : nil
        if let saved, saved >= until { return (FocusDndLease(saved: saved, applied: nil), nil) }
        return (FocusDndLease(saved: saved, applied: until), .some(until))
    }

    /// Undoes our write, unless nothing was written or the user changed DND since.
    private static func release(now: Date, current: Date?, lease: FocusDndLease?) -> Date?? {
        guard let lease, let applied = lease.applied, current == applied else { return nil }
        if let saved = lease.saved, saved > now { return .some(saved) }
        return .some(nil)
    }
}

extension FocusTimerState {
    /// Blocks finished today; 0 when the last one was on another day (the count only rolls over on a transition).
    func blocksDone(at now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.year, .month, .day], from: now) == day ? blocksToday : 0
    }
}

/// "focus 50 min on SHO-475" typed in the chat. English or Spanish ("enfoque 25 min en SHO-475");
/// the minutes and the Linear key are optional. Same pattern as windows/src/core/focus.ts.
struct FocusCommand: Equatable, Sendable {
    var minutes: Int?
    var issue: String?

    static let pattern = #"^/?(?:focus|foco|enfoque|enf[oó]cate|concentraci[oó]n)(?:\s+(\d{1,3})\s*(?:m|min|mins|minutes?|minutos?)?)?(?:\s+(?:on|en|para|sobre|for)?\s*([a-z][a-z0-9]{0,9}-\d{1,6}))?\s*[.!]?$"#

    /// nil when the text isn't a focus command (it then goes to the chat as usual).
    static func parse(_ text: String) -> FocusCommand? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let minutes = group(1).flatMap { Int($0) }.map { min(240, max(1, $0)) }
        return FocusCommand(minutes: minutes, issue: group(2)?.uppercased())
    }
}

/// The prompt shown when a block or a break runs out ("Break, 5 min?").
struct FocusNote: Equatable, Sendable {
    enum Kind: Sendable, Equatable { case blockDone, breakDone }
    let kind: Kind
    let text: String
}

/// Runs the state machine for the app: one one-shot Timer, only while a block is running.
@MainActor
final class FocusTimer {
    static let shared = FocusTimer()

    private var timer: Timer?
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "focus")

    private var current: Date? {
        let until = AppState.shared.dndUntil
        return until.flatMap { $0 > .now ? $0 : nil }
    }

    /// `issue`: a Linear key ("SHO-475") shown with the block; kept for the next blocks until Stop.
    func start(minutes: Int? = nil, issue: String? = nil) {
        if let issue { AppState.shared.focusIssue = issue }
        apply(AppState.shared.focus.start(now: .now, currentDnd: current, minutes: minutes))
    }
    func pause() { apply(AppState.shared.focus.pause(now: .now, currentDnd: current)) }
    func resume() { apply(AppState.shared.focus.resume(now: .now, currentDnd: current)) }
    func skip() { apply(AppState.shared.focus.skip(now: .now, currentDnd: current)) }
    func stop() {
        AppState.shared.focusIssue = nil
        apply(AppState.shared.focus.stop(now: .now, currentDnd: current))
    }

    /// The global shortcut and a click on the header timer: start, pause or resume.
    func toggle() {
        let f = AppState.shared.focus
        if f.phase == .idle { start() } else if f.paused { resume() } else { pause() }
    }

    /// "Keep working": no break (or the rest of it), the next block now.
    func keepWorking(minutes: Int? = nil, issue: String? = nil) {
        let f = AppState.shared.focus
        if f.phase == .shortBreak || f.phase == .longBreak {
            apply(f.skip(now: .now, currentDnd: current))
        }
        start(minutes: minutes, issue: issue)
    }

    /// A focus command typed in the chat; returns Mochi's answer.
    func run(_ command: FocusCommand) -> String {
        let s = AppState.shared
        if s.focus.phase == .focus {
            let left = FocusTimerState.format(s.focus.remaining(at: .now))
            return L("A focus block is already running (\(left) left).")
        }
        keepWorking(minutes: command.minutes, issue: command.issue)
        let mins = Int((s.focus.duration / 60).rounded())
        if let issue = s.focusIssue {
            return L("Focus: \(mins) min on \(issue). Do not disturb is on until the end of the block.")
        }
        return L("Focus: \(mins) min. Do not disturb is on until the end of the block.")
    }

    private func fire() {
        timer = nil
        apply(AppState.shared.focus.tick(now: .now, currentDnd: current), announce: true)
    }

    private func apply(_ step: FocusStep, announce: Bool = false) {
        let s = AppState.shared
        s.focus = step.state
        if let write = step.dnd {
            // Not DoNotDisturb.turnOff(): that also marks the current meeting as skipped.
            s.dndUntil = write
        }
        if let event = step.event {
            log.info("focus \(String(describing: event), privacy: .public)")
            if announce { self.announce(event) }
        }
        rearm()
    }

    /// End of a block or a break: a soft sound and the next step as a prompt in the island.
    private func announce(_ event: FocusEvent) {
        let s = AppState.shared
        let note: FocusNote
        switch event {
        case .focusDone:
            let mins = Int((s.focus.duration / 60).rounded())
            note = FocusNote(kind: .blockDone, text: s.focus.phase == .longBreak
                             ? L("Nice run! Long break, \(mins) min?")
                             : L("Block done! Break, \(mins) min?"))
            SoundEngine.shared.play("proud")
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
        case .breakDone:
            note = FocusNote(kind: .breakDone, text: L("Break's over. Back to work?"))
            SoundEngine.shared.play("pop")
        default:
            return
        }
        // An approval on screen keeps the island; Do not disturb (the user's own) keeps it closed.
        guard s.pendingApproval == nil else { return }
        s.focusNote = note
        s.noteMessage = note.text
        guard !DoNotDisturb.shared.isActive else { return }
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
    }

    /// Exactly one timer while a phase runs, none otherwise (0 % CPU when idle or paused).
    private func rearm() {
        timer?.invalidate()
        timer = nil
        guard let wait = AppState.shared.focus.nextWake(at: .now) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated { FocusTimer.shared.fire() }
        }
        timer?.tolerance = min(1, wait / 10)
    }
}
