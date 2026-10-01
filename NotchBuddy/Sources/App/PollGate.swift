import AppKit
import os

/// Decides when each integration may call its API (#7).
///
/// - Normal: every `base` seconds (the poller's own timer).
/// - Island hidden: 4× less often. Screen locked or displays asleep: no polling at all.
/// - Errors: exponential backoff (base × 2ⁿ, up to 30 min), or the server's `Retry-After`.
///   A rejected key (401/403) waits 30 min instead of hammering the API.
/// - Opening the island or unlocking the Mac refreshes whatever is out of date.
/// Manual refreshes (card button, keys saved) always go through and clear the backoff.
final class PollGate: @unchecked Sendable {
    static let shared = PollGate()

    private let lock = NSLock()
    private var base: [String: TimeInterval] = [:]
    private var lastRun: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private var blockedUntil: [String: Date] = [:]
    private var islandHidden = false
    private var screenOff = false
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "polling")

    private init() {}

    /// Called by a poller's timer. Returns false to skip this tick.
    func allow(_ id: String, every seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        base[id] = seconds
        let now = Date()
        if screenOff { return false }
        if let until = blockedUntil[id], now < until { return false }
        if islandHidden, let last = lastRun[id], now.timeIntervalSince(last) < seconds * 4 - 1 { return false }
        lastRun[id] = now
        return true
    }

    /// Manual refresh: always allowed, clears the backoff.
    func manual(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        failures[id] = 0
        blockedUntil[id] = nil
        lastRun[id] = Date()
    }

    /// Reports how a request went, to back off on errors.
    func record(_ id: String, _ response: URLResponse?) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        lock.lock(); defer { lock.unlock() }
        if (200..<400).contains(code) {
            if failures[id, default: 0] > 0 { log.info("\(id, privacy: .public) recovered") }
            failures[id] = 0
            blockedUntil[id] = nil
            return
        }
        let n = failures[id, default: 0] + 1
        failures[id] = n
        let step = base[id] ?? 60
        var wait = min(step * pow(2, Double(n)), 30 * 60)
        if code == 401 || code == 403 { wait = 30 * 60 }
        if let header = http?.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(header) {
                wait = max(wait, seconds)
            } else if let date = HTTPDateParser.date(header) {
                wait = max(wait, date.timeIntervalSinceNow)
            }
        }
        blockedUntil[id] = Date().addingTimeInterval(wait)
        log.info("\(id, privacy: .public) HTTP \(code) → next try in \(Int(wait))s")
    }

    // MARK: - Island and screen state

    func setIslandHidden(_ hidden: Bool) {
        lock.lock(); islandHidden = hidden; lock.unlock()
    }

    /// Ids whose data is older than their normal interval and that aren't backing off.
    private func staleIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let stale = base.compactMap { id, seconds -> String? in
            if let until = blockedUntil[id], now < until { return nil }
            guard let last = lastRun[id] else { return id }
            return now.timeIntervalSince(last) >= seconds ? id : nil
        }
        for id in stale { lastRun[id] = now }  // the timer won't fire a duplicate right after
        return stale
    }

    /// Island opened / Mac unlocked: refresh what went stale meanwhile.
    @MainActor
    func catchUp() {
        for id in staleIDs() { IntegrationRefresher.refresh(id, fromUser: false) }
    }

    @MainActor
    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setScreenOff(true)
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setScreenOff(false)
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setScreenOff(true)
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setScreenOff(false)
        }
    }

    private func setScreenOff(_ off: Bool) {
        lock.lock()
        let changed = screenOff != off
        screenOff = off
        lock.unlock()
        guard changed else { return }
        log.info("screen \(off ? "off" : "on", privacy: .public): polling \(off ? "paused" : "resumed", privacy: .public)")
        if !off { DispatchQueue.main.async { MainActor.assumeIsolated { self.catchUp() } } }
    }
}

/// "Retry-After: Wed, 21 Oct 2026 07:28:00 GMT"
private enum HTTPDateParser {
    static func date(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: text)
    }
}
