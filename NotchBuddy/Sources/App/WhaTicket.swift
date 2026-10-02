import AppKit
import os

// WhaTicket (the WhatsApp ticket system, github.com/canove/whaticket-community): sign in, show
// the queue and my open tickets, and — when the user turns it on — accept new tickets as they
// arrive, exactly like clicking Accept in WhaTicket. Same behaviour as windows/src-tauri/src/whaticket.rs.
//
//   POST /auth/login {email, password}        → {token, user: {id, name, queues: [{id, name, color}]}}
//   GET  /tickets?status=pending&queueIds=[…]  → {tickets: [...]}
//   GET  /tickets/:id                          → the ticket (to check it's still pending)
//   PUT  /tickets/:id {status: "open", userId} → accept; {status: "pending", userId: null} → undo
//
// The access token lasts 15 minutes: on a 401 Coucou signs in again with the password in the
// Keychain. Coucou never writes to a customer: auto-accept only assigns the ticket.

struct WhaTicketQueue: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let color: String
}

struct WhaTicketAccount: Equatable, Sendable {
    let userId: Int
    let name: String
    let queues: [WhaTicketQueue]
}

struct WhaTicketTicket: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let lastMessage: String
    let unread: Int
    let queueId: Int?
    let queue: String
    let queueColor: String
    let updatedAt: Date?
    let status: String
    let userId: Int?
    let isGroup: Bool
}

// MARK: - Pure helpers (tested in WhaTicketTests)

enum WhaTicketRules {
    /// "https://api.example.com/" → "https://api.example.com". Only http(s).
    static func normaliseBase(_ url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s.hasPrefix("https://") || s.hasPrefix("http://") ? s : nil
    }

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
    static func queueAllowed(_ queue: Int?, _ queues: [Int]) -> Bool {
        queues.isEmpty || queue.map { queues.contains($0) } == true
    }

    static func parseLogin(_ json: [String: Any]) -> (token: String, account: WhaTicketAccount)? {
        guard let token = json["token"] as? String, let user = json["user"] as? [String: Any],
              let id = user["id"] as? Int else { return nil }
        let queues = (user["queues"] as? [[String: Any]] ?? []).compactMap { q -> WhaTicketQueue? in
            guard let qid = q["id"] as? Int else { return nil }
            return WhaTicketQueue(id: qid, name: q["name"] as? String ?? "", color: q["color"] as? String ?? "")
        }
        return (token, WhaTicketAccount(userId: id, name: user["name"] as? String ?? "", queues: queues))
    }

    static func parseTicket(_ t: [String: Any]) -> WhaTicketTicket? {
        guard let id = t["id"] as? Int else { return nil }
        let contact = t["contact"] as? [String: Any]
        let number = contact?["number"] as? String ?? ""
        let contactName = (contact?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let queue = t["queue"] as? [String: Any]
        return WhaTicketTicket(
            id: id,
            name: contactName ?? (number.isEmpty ? "?" : number),
            lastMessage: t["lastMessage"] as? String ?? "",
            unread: t["unreadMessages"] as? Int ?? 0,
            queueId: t["queueId"] as? Int,
            queue: queue?["name"] as? String ?? "",
            queueColor: queue?["color"] as? String ?? "",
            updatedAt: (t["updatedAt"] as? String).flatMap(LinearAPI.date),
            status: t["status"] as? String ?? "",
            userId: t["userId"] as? Int,
            isGroup: t["isGroup"] as? Bool ?? false)
    }
}

// MARK: - API

@MainActor
enum WhaTicketAPI {
    static let urlKey = "whaticket-url"
    static let webURLKey = "whaticket-web-url"
    static let emailKey = "whaticket-email"
    static let passwordKey = "whaticket-password"

    private static var token: String?
    private(set) static var account: WhaTicketAccount?

    enum Failure: LocalizedError {
        case notConfigured, wrongLogin, notWhaTicket, unreachable(String), http(Int), taken, tooLate
        var errorDescription: String? {
            switch self {
            case .notConfigured: return L("Add the WhaTicket URL, email and password first.")
            case .wrongLogin: return L("Wrong email or password")
            case .notWhaTicket: return L("That URL doesn't answer like WhaTicket.")
            case .unreachable(let base): return L("Can't reach \(base)")
            case .http(let code): return L("WhaTicket error \(code)")
            case .taken: return L("Someone already took that ticket.")
            case .tooLate: return L("Too late to undo — reopen it in WhaTicket.")
            }
        }
    }

    static var base: String? { Secrets.store.get(urlKey).flatMap(WhaTicketRules.normaliseBase) }
    static var isConfigured: Bool {
        base != nil && !(Secrets.store.get(emailKey) ?? "").isEmpty && !(Secrets.store.get(passwordKey) ?? "").isEmpty
    }

    /// Credentials changed or "Sign in" clicked: start over.
    static func forget() {
        token = nil
        account = nil
    }

    @discardableResult
    static func login() async throws -> WhaTicketAccount {
        guard let base, let email = Secrets.store.get(emailKey), let password = Secrets.store.get(passwordKey),
              let url = URL(string: "\(base)/auth/login") else { throw Failure.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw Failure.unreachable(base) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw Failure.wrongLogin }
        guard code == 200 else { throw Failure.http(code) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let parsed = WhaTicketRules.parseLogin(json) else { throw Failure.notWhaTicket }
        token = parsed.token
        account = parsed.account
        return parsed.account
    }

    /// One authorised request; signs in (again) when needed.
    static func call(_ method: String, _ path: String, body: [String: Any?]? = nil) async throws -> Any {
        for attempt in 0..<2 {
            if token == nil || attempt == 1 { try await login() }
            guard let base, let token, let url = URL(string: base + path) else { throw Failure.notConfigured }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
            }
            let data: Data, response: URLResponse
            do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw Failure.unreachable(base) }
            PollGate.shared.record("integration_whaticket", response)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (code == 401 || code == 403) && attempt == 0 { continue }
            guard (200..<300).contains(code) else { throw Failure.http(code) }
            return (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
        }
        throw Failure.wrongLogin
    }

    static func tickets(status: String, queues: [Int]) async throws -> [WhaTicketTicket] {
        let ids = "[" + queues.map(String.init).joined(separator: ",") + "]"
        let encoded = ids.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ids
        let json = try await call("GET", "/tickets?status=\(status)&showAll=false&pageNumber=1&queueIds=\(encoded)")
        let list = (json as? [String: Any])?["tickets"] as? [[String: Any]] ?? []
        return list.compactMap(WhaTicketRules.parseTicket)
    }

    /// Accepts as me — only if it's still pending and nobody has it.
    static func accept(_ id: Int) async throws {
        let current = try await call("GET", "/tickets/\(id)") as? [String: Any] ?? [:]
        guard current["status"] as? String == "pending", current["userId"] as? Int == nil else { throw Failure.taken }
        guard let account else { throw Failure.notConfigured }
        _ = try await call("PUT", "/tickets/\(id)", body: ["status": "open", "userId": account.userId])
    }

    static func putBack(_ id: Int) async throws {
        _ = try await call("PUT", "/tickets/\(id)", body: ["status": "pending", "userId": nil])
    }

    /// The web app's address (the "web URL" setting, else the API URL).
    static func webURL(_ id: Int?) -> URL? {
        let base = Secrets.store.get(webURLKey).flatMap(WhaTicketRules.normaliseBase) ?? self.base
        guard let base else { return nil }
        return URL(string: id.map { "\(base)/tickets/\($0)" } ?? "\(base)/tickets")
    }
}

// MARK: - Settings (UserDefaults; the credentials are in the Keychain)

enum WhaTicketSettings {
    static var autoAccept: Bool {
        get { UserDefaults.standard.bool(forKey: "whaticketAutoAccept") }
        set { UserDefaults.standard.set(newValue, forKey: "whaticketAutoAccept") }
    }
    static var queues: [Int] {
        get { UserDefaults.standard.array(forKey: "whaticketQueues") as? [Int] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "whaticketQueues") }
    }
    /// "09:00-18:00"; empty = any time.
    static var hours: String {
        get { UserDefaults.standard.string(forKey: "whaticketHours") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "whaticketHours") }
    }
}

// MARK: - Poller

@MainActor
final class WhaTicketPoller {
    static let shared = WhaTicketPoller()
    private var timer: Timer?
    private var seenPending: Set<Int>?
    private var unread: [Int: Int] = [:]
    private var mineReady = false
    /// Tickets Coucou accepted on its own, for Undo (two minutes).
    private var accepted: [Int: Date] = [:]
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "whaticket")
    static let id = "integration_whaticket"

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard PollGate.shared.allow(WhaTicketPoller.id, every: 20) else { return }
                WhaTicketPoller.shared.pollNow()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { WhaTicketPoller.shared.pollNow() }
    }

    /// Only while the pill is on, like every integration.
    private var enabled: Bool {
        WhaTicketAPI.isConfigured && AppState.shared.activeIntegrations.contains(Self.id)
    }

    func reset() {
        WhaTicketAPI.forget()
        seenPending = nil
        unread = [:]
        mineReady = false
        accepted = [:]
    }

    func pollNow() {
        guard enabled else { return }
        Task { @MainActor in await poll() }
    }

    private func poll() async {
        let state = AppState.shared
        do {
            if WhaTicketAPI.account == nil { try await WhaTicketAPI.login() }
            guard let account = WhaTicketAPI.account else { return }
            let queueIds = account.queues.map(\.id)
            let pending = try await WhaTicketAPI.tickets(status: "pending", queues: queueIds)
            let open = (try? await WhaTicketAPI.tickets(status: "open", queues: queueIds)) ?? []
            let mine = open.filter { $0.userId == account.userId }

            var event: (label: String, detail: String?)?
            var acceptedNow = false

            // New tickets in the queue (the first poll only fills the card).
            let ids = Set(pending.map(\.id))
            let fresh = seenPending.map { seen in pending.filter { !seen.contains($0.id) } } ?? []
            seenPending = ids
            let minutes = Calendar.current.component(.hour, from: .now) * 60 + Calendar.current.component(.minute, from: .now)
            for t in fresh {
                let can = WhaTicketSettings.autoAccept && !DoNotDisturb.shared.isActive && !t.isGroup
                    && WhaTicketRules.queueAllowed(t.queueId, WhaTicketSettings.queues)
                    && WhaTicketRules.inHours(WhaTicketSettings.hours, minutes: minutes)
                if can {
                    do {
                        try await WhaTicketAPI.accept(t.id)
                        log.info("auto-accepted ticket \(t.id)")
                        accepted[t.id] = .now
                        acceptedNow = true
                        let detail = [t.queue, t.lastMessage].filter { !$0.isEmpty }.joined(separator: " · ")
                        event = (L("Accepted · \(t.name)"), detail.isEmpty ? nil : detail)
                        continue
                    } catch {
                        log.error("auto-accept \(t.id) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                event = (L("New ticket · \(t.name)"), t.lastMessage.isEmpty ? nil : t.lastMessage)
            }

            // New messages on my tickets.
            var next: [Int: Int] = [:]
            for t in mine {
                if event == nil, mineReady, let before = unread[t.id], t.unread > before {
                    event = (L("Message · \(t.name)"), t.lastMessage.isEmpty ? nil : t.lastMessage)
                }
                next[t.id] = t.unread
            }
            unread = next
            mineReady = true
            accepted = accepted.filter { Date.now.timeIntervalSince($0.value) < 120 }

            // Tickets accepted just now are mine already: list them on the card.
            let mineNow = acceptedNow
                ? ((try? await WhaTicketAPI.tickets(status: "open", queues: queueIds)) ?? open).filter { $0.userId == account.userId }
                : mine
            if acceptedNow { for t in mineNow where unread[t.id] == nil { unread[t.id] = t.unread } }
            state.whaticketUser = account.name
            state.whaticketPending = Array(pending.prefix(8))
            state.whaticketPendingCount = pending.count
            state.whaticketMine = Array(mineNow.prefix(8))
            state.whaticketMineCount = mineNow.count
            state.whaticketUndoable = Set(accepted.keys)
            state.whaticketError = nil
            state.whaticketLoaded = true
            if let event { announce(event.label, event.detail) }
        } catch {
            state.whaticketError = error.localizedDescription
            state.whaticketLoaded = true
        }
    }

    /// The pill lights up, plays a sound and shows the compact island — like a Vercel deploy.
    private func announce(_ label: String, _ detail: String?) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.id }) else { return }
        state.tasks[idx].state = .finished
        state.tasks[idx].steps = detail.map { [label, $0] } ?? [label]
        if state.focusId != Self.id { state.tasks[idx].pillBadge = .finished }
        guard !DoNotDisturb.shared.isActive else { return }
        SoundEngine.shared.play("finish")
        NotificationCenter.default.post(name: .hookReveal, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.id }), state.tasks[i].state == .finished else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }

    // MARK: Actions (only ever on a click)

    func accept(_ id: Int) async throws {
        try await WhaTicketAPI.accept(id)
        log.info("accepted ticket \(id)")
        await poll()
    }

    func undo(_ id: Int) async throws {
        guard let at = accepted[id], Date.now.timeIntervalSince(at) < 120 else { throw WhaTicketAPI.Failure.tooLate }
        try await WhaTicketAPI.putBack(id)
        accepted[id] = nil
        log.info("undid ticket \(id)")
        await poll()
    }
}
