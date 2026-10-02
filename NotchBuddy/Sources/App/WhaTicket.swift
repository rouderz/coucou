import AppKit
import os

// WhaTicket (whaticket.com) through the browser. Same behaviour as windows/src-tauri/src/whaticket.rs.
//
// whaticket.com only lets admins create API tokens, so Coucou doesn't sign in at all. The
// "Coucou for WhaTicket" extension (extensions/whaticket, set up from Settings → WhaTicket) runs
// in the user's own whaticket.com tab, reads the queue with that tab's session, and checks in here
// every ~15 s through native messaging: coucou-native-host → nb.sock → HookServer →
// `WhaTicketBridge.handle`. Our answer carries the tickets to accept — one the user clicked, or one
// auto-accept picked — and the extension sends the same POST /tickets/{id}/assign as the web app's
// Accept button, then tells us how it went.
//
// Coucou holds no WhaTicket credentials and makes no WhaTicket requests of its own. It never writes
// to a customer: accepting only assigns the ticket.

struct WhaTicketQueue: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let color: String
}

struct WhaTicketTicket: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let lastMessage: String
    let unread: Int
    let queueId: String?
    let queue: String
    let queueColor: String
    let updatedAt: Date?
    let isGroup: Bool
    /// An AI agent is answering it: never auto-accepted.
    let aiHandling: Bool
}

// MARK: - Pure helpers (tested in WhaTicketTests)

enum WhaTicketRules {
    static let web = "https://app.whaticket.com"

    /// "09:00-18:00" (or "22:00-06:00" across midnight); empty or unreadable = any time.
    static func inHours(_ spec: String, minutes now: Int) -> Bool {
        let spec = spec.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return true }
        func parse(_ s: Substring) -> Int? {
            let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h <= 24, m < 60 else { return nil }
            return h * 60 + m
        }
        let ends = spec.split(separator: "-", maxSplits: 1)
        guard ends.count == 2, let from = parse(ends[0]), let to = parse(ends[1]) else { return true }
        return from <= to ? (now >= from && now < to) : (now >= from || now < to)
    }

    /// Empty list = any of my queues (and tickets with no queue).
    static func queueAllowed(_ queue: String?, _ queues: [String]) -> Bool {
        queues.isEmpty || queue.map { queues.contains($0) } == true
    }

    /// An id as text: a number saved by an older build, or a UUID.
    static func textID(_ value: Any?) -> String? {
        switch value {
        case let s as String where !s.isEmpty: return s
        case let n as Int: return String(n)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Ticket and queue ids are UUIDs (or numbers); nothing else goes back to the browser.
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func text(_ v: Any?, max: Int = 300) -> String {
        String((v as? String ?? "").prefix(max))
    }

    /// The tickets of a snapshot, keeping only well-formed ones.
    static func tickets(_ msg: [String: Any], _ key: String) -> [WhaTicketTicket] {
        let list = (msg[key] as? [[String: Any]] ?? []).compactMap { t -> WhaTicketTicket? in
            guard let id = t["id"] as? String, validID(id) else { return nil }
            return WhaTicketTicket(
                id: id,
                name: text(t["name"]).isEmpty ? "?" : text(t["name"]),
                lastMessage: text(t["lastMessage"]),
                unread: t["unread"] as? Int ?? 0,
                queueId: (t["queueId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                queue: text(t["queue"], max: 80),
                queueColor: text(t["queueColor"], max: 20),
                updatedAt: (t["updatedAt"] as? String).flatMap(LinearAPI.date),
                isGroup: t["isGroup"] as? Bool ?? false,
                aiHandling: t["aiHandling"] as? Bool ?? false)
        }
        return Array(list.prefix(200))
    }

    /// The snapshot's queues, for Settings → "Only from".
    static func queues(_ msg: [String: Any]) -> [WhaTicketQueue] {
        let list = (msg["queues"] as? [[String: Any]] ?? []).compactMap { q -> WhaTicketQueue? in
            guard let id = q["id"] as? String, validID(id) else { return nil }
            return WhaTicketQueue(id: id, name: text(q["name"], max: 80), color: text(q["color"], max: 20))
        }
        return Array(list.prefix(100))
    }

    /// What the card says when the extension reports a problem.
    static func errorText(_ code: String) -> String {
        switch code {
        case "signed_out": return L("Sign in to whaticket.com in Chrome or Edge.")
        case "session": return L("whaticket.com's session expired: use the tab once (or sign in again).")
        default: return String(code.prefix(200))
        }
    }

    /// The web app's address for a ticket.
    static func webURL(_ id: String?) -> URL? {
        if let id, validID(id) { return URL(string: "\(web)/tickets/\(id)") }
        return URL(string: "\(web)/tickets")
    }
}

// MARK: - Settings (UserDefaults)

enum WhaTicketSettings {
    static var autoAccept: Bool {
        get { UserDefaults.standard.bool(forKey: "whaticketAutoAccept") }
        set { UserDefaults.standard.set(newValue, forKey: "whaticketAutoAccept") }
    }
    /// Queue ids as text; numbers saved by an older build still load.
    static var queues: [String] {
        get { (UserDefaults.standard.array(forKey: "whaticketQueues") ?? []).compactMap { WhaTicketRules.textID($0) } }
        set { UserDefaults.standard.set(newValue, forKey: "whaticketQueues") }
    }
    /// "09:00-18:00"; empty = any time.
    static var hours: String {
        get { UserDefaults.standard.string(forKey: "whaticketHours") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "whaticketHours") }
    }
}

// MARK: - The extension's check-ins

@MainActor
final class WhaTicketBridge {
    static let shared = WhaTicketBridge()
    static let id = "integration_whaticket"
    /// How often the extension checks in (seconds).
    static let interval = 15
    /// After this, the tab is closed or asleep: the card says so and Accept is off.
    nonisolated static let staleAfter: TimeInterval = 60
    /// A click waits at most this long for the extension to pick it up.
    private static let queuedFor: TimeInterval = 90

    /// Pending ids seen so far (nil until the first snapshot, which is silent).
    private var seen: Set<String>?
    private var unread: [String: Int] = [:]
    private var mineReady = false
    /// Tickets to accept, waiting for the next check-in.
    private var queued: [(id: String, at: Date)] = []
    /// Sent to the extension, waiting for its result.
    private var inFlight: [String: Date] = [:]
    private var names: [String: String] = [:]
    /// Picked by auto-accept rather than clicked.
    private var auto: Set<String> = []
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "whaticket")

    private var enabled: Bool { AppState.shared.activeIntegrations.contains(Self.id) }

    /// One message from the extension; returns the answer it gets.
    func handle(_ msg: [String: Any]) -> [String: Any] {
        // Pill off: Coucou isn't watching WhaTicket. Check in rarely.
        guard enabled else {
            startOver()
            return ["commands": [Any](), "interval": 60]
        }
        switch msg["kind"] as? String {
        case "snapshot": return snapshot(msg)
        case "results": return results(msg)
        default: return ["commands": [Any](), "interval": Self.interval]
        }
    }

    /// Forget what we've seen, so the next snapshot only fills the card: no alerts and no
    /// auto-accept for a backlog that piled up while we weren't watching.
    private func startOver() {
        seen = nil
        unread = [:]
        mineReady = false
    }

    private func snapshot(_ msg: [String: Any]) -> [String: Any] {
        let state = AppState.shared
        if let code = msg["error"] as? String {
            state.whaticketError = WhaTicketRules.errorText(code)
            state.whaticketSeenAt = .now
            state.whaticketLoaded = true
            return ["commands": [Any](), "interval": Self.interval]
        }
        // No check-in for a while: the tab was closed or asleep. Start over, silently.
        if state.whaticketSeenAt.map({ Date.now.timeIntervalSince($0) > Self.staleAfter }) ?? true {
            startOver()
        }
        let pending = WhaTicketRules.tickets(msg, "pending")
        let mine = WhaTicketRules.tickets(msg, "mine")
        for t in pending + mine { names[t.id] = t.name }
        var event: (label: String, detail: String?)?

        // New tickets in the queue (the first snapshot only fills the card).
        let fresh = seen.map { seen in pending.filter { !seen.contains($0.id) } } ?? []
        seen = Set(pending.map(\.id))
        let minutes = Calendar.current.component(.hour, from: .now) * 60 + Calendar.current.component(.minute, from: .now)
        for t in fresh {
            let can = WhaTicketSettings.autoAccept && !DoNotDisturb.shared.isActive && !t.isGroup && !t.aiHandling
                && WhaTicketRules.queueAllowed(t.queueId, WhaTicketSettings.queues)
                && WhaTicketRules.inHours(WhaTicketSettings.hours, minutes: minutes)
            if can && inFlight[t.id] == nil && !queued.contains(where: { $0.id == t.id }) {
                queued.append((t.id, .now))
                auto.insert(t.id)
                continue  // announced once the extension confirms it
            }
            event = (L("New ticket · \(t.name)"), t.lastMessage.isEmpty ? nil : t.lastMessage)
        }

        // New messages on my tickets (a ticket that just became mine isn't news).
        var next: [String: Int] = [:]
        for t in mine {
            if event == nil, mineReady, let before = unread[t.id], t.unread > before {
                event = (L("Message · \(t.name)"), t.lastMessage.isEmpty ? nil : t.lastMessage)
            }
            next[t.id] = t.unread
        }
        unread = next
        mineReady = true

        let user = (msg["user"] as? [String: Any])?["name"] as? String ?? ""
        state.whaticketUser = user.isEmpty ? nil : String(user.prefix(80))
        state.whaticketQueues = WhaTicketRules.queues(msg)
        state.whaticketPending = Array(pending.prefix(8))
        state.whaticketPendingCount = pending.count
        state.whaticketMine = Array(mine.prefix(8))
        state.whaticketMineCount = mine.count
        state.whaticketError = nil
        state.whaticketSeenAt = .now
        state.whaticketLoaded = true
        let reply = takeCommands()
        if let event { announce(event.label, event.detail, success: true) }
        return reply
    }

    private func results(_ msg: [String: Any]) -> [String: Any] {
        var event: (label: String, detail: String?, success: Bool)?
        for r in msg["results"] as? [[String: Any]] ?? [] {
            guard let id = r["id"] as? String else { continue }
            inFlight[id] = nil
            let wasAuto = auto.remove(id) != nil
            let name = names[id] ?? "?"
            if r["ok"] as? Bool == true {
                log.info("\(wasAuto ? "auto-accepted" : "accepted", privacy: .public) ticket \(id, privacy: .public)")
                event = (L("Accepted · \(name)"), nil, true)
            } else {
                let why = WhaTicketRules.errorText(r["error"] as? String ?? "")
                log.error("accepting \(id, privacy: .public) failed: \(why, privacy: .public)")
                event = (L("Couldn't accept · \(name)"), why, false)
            }
        }
        // Clicks queued meanwhile wait for the next snapshot, where the extension checks they
        // are still pending before accepting them.
        publishAccepting()
        if let event { announce(event.label, event.detail, success: event.success) }
        return ["commands": [Any](), "interval": Self.interval]
    }

    /// The queued accepts go to the extension now; stale clicks are dropped.
    private func takeCommands() -> [String: Any] {
        queued.removeAll { Date.now.timeIntervalSince($0.at) >= Self.queuedFor }
        inFlight = inFlight.filter { Date.now.timeIntervalSince($0.value) < Self.queuedFor }
        let ids = queued.map(\.id)
        queued.removeAll()
        for id in ids { inFlight[id] = .now }
        publishAccepting()
        return ["commands": ids.map { ["op": "accept", "id": $0] }, "interval": Self.interval]
    }

    private func publishAccepting() {
        AppState.shared.whaticketAccepting = Set(queued.map(\.id)).union(inFlight.keys)
    }

    // MARK: Actions (only ever on a click)

    /// Accept from the card: picked up at the extension's next check-in (a few seconds).
    func accept(_ id: String) throws {
        guard WhaTicketRules.validID(id) else { throw Failure.message(L("Unknown ticket")) }
        guard let seenAt = AppState.shared.whaticketSeenAt, Date.now.timeIntervalSince(seenAt) < Self.staleAfter else {
            throw Failure.message(L("Open whaticket.com in Chrome or Edge (with the Coucou extension) to accept from here."))
        }
        if inFlight[id] == nil && !queued.contains(where: { $0.id == id }) {
            queued.append((id, .now))
            log.info("accept queued for ticket \(id, privacy: .public)")
        }
        publishAccepting()
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// The pill lights up, plays a sound and shows the compact island — like a Vercel deploy.
    private func announce(_ label: String, _ detail: String?, success: Bool) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.id }) else { return }
        state.tasks[idx].state = success ? .finished : .error
        state.tasks[idx].steps = detail.map { [label, $0] } ?? [label]
        if state.focusId != Self.id { state.tasks[idx].pillBadge = success ? .finished : .error }
        guard !DoNotDisturb.shared.isActive else { return }
        SoundEngine.shared.play(success ? "finish" : "error")
        NotificationCenter.default.post(name: .hookReveal, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.id }),
                  state.tasks[i].state == .finished || state.tasks[i].state == .error else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }
}
