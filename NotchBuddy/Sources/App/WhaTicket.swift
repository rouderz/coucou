import AppKit
import os

// WhaTicket, the WhatsApp ticket system: show the queue and my open tickets, and — when the user
// turns it on — accept new tickets as they arrive. Same behaviour as windows/src-tauri/src/whaticket.rs.
//
// • whaticket.com (hosted) — an API token from Integrations → Tokens, public API at
//   https://api.whaticket.com/api/v1: GET /me, /users, /queues, /tickets?status=…, /tickets/{id},
//   POST /tickets/{id}/transfer {userId} to accept. IDs are UUIDs. A token has no user, so Coucou
//   finds yours by your email. There's no way to put a ticket back in the queue: no Undo.
//   (Email + password sign-in there needs reCAPTCHA and an emailed code, which an app can't do.)
// • WhaTicket Community (self-hosted): POST /auth/login {email, password}, GET /tickets,
//   PUT /tickets/:id {status, userId} to accept or put back. The 15-minute token is renewed by
//   signing in again with the password in the Keychain.
//
// Coucou never writes to a customer: auto-accept only assigns the ticket.

struct WhaTicketQueue: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let color: String
}

struct WhaTicketAccount: Equatable, Sendable {
    let userId: String
    let name: String
    let queues: [WhaTicketQueue]
    /// whaticket.com (API token) rather than a self-hosted WhaTicket.
    var cloud = false
    /// whaticket.com: every queue of the company (names and colours for the card).
    var allQueues: [WhaTicketQueue] = []
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
    let status: String
    let userId: String?
    let isGroup: Bool
}

// MARK: - Pure helpers (tested in WhaTicketTests)

enum WhaTicketRules {
    static let cloudAPI = "https://api.whaticket.com"
    static let cloudWeb = "https://app.whaticket.com"

    /// "https://api.example.com/" → "https://api.example.com". Only http(s).
    static func normaliseBase(_ url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s.hasPrefix("https://") || s.hasPrefix("http://") ? s : nil
    }

    /// The whaticket.com API root: the URL setting if any (with /api/v1 added), else the default.
    static func cloudBase(_ url: String?) -> String {
        let base = url.flatMap(normaliseBase) ?? cloudAPI
        return base.hasSuffix("/api/v1") ? base : base + "/api/v1"
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
    static func queueAllowed(_ queue: String?, _ queues: [String]) -> Bool {
        queues.isEmpty || queue.map { queues.contains($0) } == true
    }

    /// An id as text: a number (self-hosted) or a UUID (whaticket.com).
    static func textID(_ value: Any?) -> String? {
        switch value {
        case let s as String where !s.isEmpty: return s
        case let n as Int: return String(n)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// A list under `key`, or the body itself when it's already a list.
    static func list(_ json: Any?, _ key: String) -> [[String: Any]] {
        if let array = json as? [[String: Any]] { return array }
        return (json as? [String: Any])?[key] as? [[String: Any]] ?? []
    }

    static func parseQueue(_ q: [String: Any]) -> WhaTicketQueue? {
        guard let id = textID(q["id"]) else { return nil }
        return WhaTicketQueue(id: id, name: q["name"] as? String ?? "", color: q["color"] as? String ?? "")
    }

    /// Self-hosted login answer → (token, account).
    static func parseLogin(_ json: [String: Any]) -> (token: String, account: WhaTicketAccount)? {
        guard let token = json["token"] as? String, let user = json["user"] as? [String: Any],
              let userId = textID(user["id"]) else { return nil }
        let queues = list(user, "queues").compactMap(parseQueue)
        return (token, WhaTicketAccount(userId: userId, name: user["name"] as? String ?? "", queues: queues))
    }

    /// whaticket.com: me among the company's users, by email (case-insensitive).
    static func findUser(_ users: Any?, email: String) -> [String: Any]? {
        let wanted = email.trimmingCharacters(in: .whitespaces).lowercased()
        return list(users, "users").first {
            ($0["email"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }
    }

    /// whaticket.com permissions the token's profile still lacks (none when the answer doesn't list them).
    static func missingPermissions(_ me: [String: Any]) -> [String] {
        let needed = ["tickets:view", "tickets:viewAll", "tickets:viewPending", "tickets:transfer", "users:view"]
        let have = (me["permissions"] as? [Any] ?? []).compactMap { $0 as? String ?? ($0 as? [String: Any])?["name"] as? String }
        guard !have.isEmpty else { return [] }
        return needed.filter { !have.contains($0) }
    }

    static func parseTicket(_ t: [String: Any], queues: [WhaTicketQueue] = []) -> WhaTicketTicket? {
        guard let id = textID(t["id"]) else { return nil }
        let contact = t["contact"] as? [String: Any]
        let number = contact?["number"] as? String ?? ""
        let contactName = (contact?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let queueId = textID(t["queueId"])
        let queue = (t["queue"] as? [String: Any]).flatMap(parseQueue) ?? queueId.flatMap { qid in queues.first { $0.id == qid } }
        return WhaTicketTicket(
            id: id,
            name: contactName ?? (number.isEmpty ? "?" : number),
            lastMessage: t["lastMessage"] as? String ?? "",
            unread: t["unreadMessages"] as? Int ?? 0,
            queueId: queueId,
            queue: queue?.name ?? "",
            queueColor: queue?.color ?? "",
            updatedAt: (t["updatedAt"] as? String).flatMap(LinearAPI.date),
            status: t["status"] as? String ?? "",
            userId: textID(t["userId"]),
            isGroup: t["isGroup"] as? Bool ?? false)
    }

    /// The error text for an answer, naming the cause when WhaTicket says it.
    static func describe(code: Int, body: Any?) -> String {
        let json = body as? [String: Any]
        let what = (json?["error"] as? String) ?? (json?["message"] as? String) ?? ""
        if what.hasPrefix("ERR_SHOULD_LOGIN_BY") {
            return L("This WhaTicket asks for a code to sign in: use an API token instead (whaticket.com → Integrations → Tokens).")
        }
        if code == 429 { return L("WhaTicket says too many attempts — wait a minute and try again.") }
        return what.isEmpty ? L("WhaTicket error \(code)") : L("WhaTicket answered \(code): \(what)")
    }
}

// MARK: - API

@MainActor
enum WhaTicketAPI {
    static let tokenKey = "whaticket-token"
    static let urlKey = "whaticket-url"
    static let webURLKey = "whaticket-web-url"
    static let emailKey = "whaticket-email"
    static let passwordKey = "whaticket-password"

    private static var bearer: String?
    private static var base: String?
    private(set) static var account: WhaTicketAccount?

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private static func secret(_ key: String) -> String? {
        Secrets.store.get(key).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    static var usesToken: Bool { secret(tokenKey) != nil }
    static var isConfigured: Bool {
        usesToken || (secret(urlKey).flatMap(WhaTicketRules.normaliseBase) != nil && secret(emailKey) != nil && secret(passwordKey) != nil)
    }

    /// Credentials changed or "Sign in" clicked: start over.
    static func forget() {
        bearer = nil
        base = nil
        account = nil
    }

    private static func send(_ method: String, _ url: String, token: String?, body: [String: Any?]? = nil) async throws -> (Int, Any?) {
        guard let u = URL(string: url) else { throw Failure.message(L("That URL doesn't answer like WhaTicket.")) }
        var req = URLRequest(url: u, timeoutInterval: 12)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch {
            throw Failure.message(L("Can't reach \(u.host ?? url) · \(error.localizedDescription)"))
        }
        PollGate.shared.record("integration_whaticket", response)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
    }

    @discardableResult
    static func login() async throws -> WhaTicketAccount {
        if let token = secret(tokenKey) {
            let api = WhaTicketRules.cloudBase(secret(urlKey))
            let (code, me) = try await send("GET", api + "/me", token: token)
            if code == 401 || code == 403 {
                throw Failure.message(L("WhaTicket refused the token — check it in whaticket.com → Integrations → Tokens."))
            }
            guard code == 200 else { throw Failure.message(WhaTicketRules.describe(code: code, body: me)) }
            let missing = WhaTicketRules.missingPermissions(me as? [String: Any] ?? [:])
            if !missing.isEmpty {
                throw Failure.message(L("The token's profile needs these permissions: \(missing.joined(separator: ", "))"))
            }
            guard let email = secret(emailKey) else {
                throw Failure.message(L("Add the email you sign in to WhaTicket with, so Coucou knows which agent you are."))
            }
            let (usersCode, users) = try await send("GET", api + "/users", token: token)
            guard usersCode == 200 else { throw Failure.message(WhaTicketRules.describe(code: usersCode, body: users)) }
            guard let user = WhaTicketRules.findUser(users, email: email), let userId = WhaTicketRules.textID(user["id"]) else {
                throw Failure.message(L("No WhaTicket user has that email — check it."))
            }
            let (_, queuesJSON) = try await send("GET", api + "/queues", token: token)
            let all = WhaTicketRules.list(queuesJSON, "queues").compactMap(WhaTicketRules.parseQueue)
            let mine: [WhaTicketQueue] = ((user["queues"] as? [Any]) ?? []).compactMap { q in
                guard let qid = WhaTicketRules.textID((q as? [String: Any])?["id"] ?? q) else { return nil }
                return all.first { $0.id == qid } ?? WhaTicketQueue(id: qid, name: "", color: "")
            }
            let a = WhaTicketAccount(userId: userId, name: user["name"] as? String ?? "", queues: mine, cloud: true, allQueues: all)
            bearer = token
            base = api
            account = a
            return a
        }

        guard let url = secret(urlKey).flatMap(WhaTicketRules.normaliseBase), let email = secret(emailKey),
              let password = secret(passwordKey) else {
            throw Failure.message(L("Add your WhaTicket token (or URL, email and password) first."))
        }
        let (code, json) = try await send("POST", url + "/auth/login", token: nil, body: ["email": email, "password": password])
        if code == 401 || code == 403 {
            let why = (json as? [String: Any])?["error"] as? String ?? ""
            throw Failure.message(why.hasPrefix("ERR_SHOULD_LOGIN_BY") ? WhaTicketRules.describe(code: code, body: json) : L("Wrong email or password"))
        }
        guard code == 200 else { throw Failure.message(WhaTicketRules.describe(code: code, body: json)) }
        guard let parsed = (json as? [String: Any]).flatMap(WhaTicketRules.parseLogin) else {
            throw Failure.message(L("That URL doesn't answer like WhaTicket."))
        }
        bearer = parsed.token
        base = url
        account = parsed.account
        return parsed.account
    }

    /// One authorised request; signs in (again) when needed (a self-hosted token expires).
    static func call(_ method: String, _ path: String, body: [String: Any?]? = nil) async throws -> Any? {
        for attempt in 0..<2 {
            if bearer == nil || attempt == 1 { try await login() }
            guard let base, let bearer, let account else { throw Failure.message(L("Add your WhaTicket token (or URL, email and password) first.")) }
            let (code, json) = try await send(method, base + path, token: bearer, body: body)
            if (code == 401 || code == 403) && attempt == 0 && !account.cloud { continue }
            if code == 401 { throw Failure.message(L("WhaTicket refused the token — check it in whaticket.com → Integrations → Tokens.")) }
            guard (200..<300).contains(code) else { throw Failure.message(WhaTicketRules.describe(code: code, body: json)) }
            return json
        }
        throw Failure.message(L("Wrong email or password"))
    }

    /// Pending tickets in my queues, and my open tickets.
    static func fetch(_ account: WhaTicketAccount) async throws -> (pending: [WhaTicketTicket], mine: [WhaTicketTicket]) {
        let names = account.allQueues + account.queues
        let mineQueues = account.queues.map(\.id)
        if account.cloud {
            let pending = WhaTicketRules.list(try await call("GET", "/tickets?status=pending"), "tickets")
                .compactMap { WhaTicketRules.parseTicket($0, queues: names) }
                .filter { t in mineQueues.isEmpty || t.queueId.map { mineQueues.contains($0) } ?? true }
            let user = account.userId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? account.userId
            let open = (try? await call("GET", "/tickets?status=open&userIds=\(user)")) ?? nil
            let mine = WhaTicketRules.list(open, "tickets").compactMap { WhaTicketRules.parseTicket($0, queues: names) }
            return (pending, mine)
        }
        let ids = "[" + mineQueues.map { Int($0).map(String.init) ?? "\"\($0)\"" }.joined(separator: ",") + "]"
        let encoded = ids.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ids
        let path = { (status: String) in "/tickets?status=\(status)&showAll=false&pageNumber=1&queueIds=\(encoded)" }
        let pending = WhaTicketRules.list(try await call("GET", path("pending")), "tickets").compactMap { WhaTicketRules.parseTicket($0) }
        let open = (try? await call("GET", path("open"))) ?? nil
        let mine = WhaTicketRules.list(open, "tickets").compactMap { WhaTicketRules.parseTicket($0) }.filter { $0.userId == account.userId }
        return (pending, mine)
    }

    private static func check(_ id: String) throws {
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw Failure.message("Unknown ticket")
        }
    }

    /// Accepts as me — only if it's still pending and nobody has it.
    static func accept(_ id: String) async throws {
        try check(id)
        let json = try await call("GET", "/tickets/\(id)") as? [String: Any] ?? [:]
        let current = json["ticket"] as? [String: Any] ?? json
        guard current["status"] as? String == "pending", WhaTicketRules.textID(current["userId"]) == nil else {
            throw Failure.message(L("Someone already took that ticket."))
        }
        guard let account else { throw Failure.message(L("Add your WhaTicket token (or URL, email and password) first.")) }
        if account.cloud {
            _ = try await call("POST", "/tickets/\(id)/transfer", body: ["userId": account.userId])
        } else {
            let user: Any = Int(account.userId) ?? account.userId
            _ = try await call("PUT", "/tickets/\(id)", body: ["status": "open", "userId": user])
        }
    }

    /// Self-hosted only: back to the queue.
    static func putBack(_ id: String) async throws {
        try check(id)
        if account?.cloud == true {
            throw Failure.message(L("whaticket.com can't put a ticket back in the queue — open it in WhaTicket."))
        }
        _ = try await call("PUT", "/tickets/\(id)", body: ["status": "pending", "userId": nil])
    }

    /// The web app's address for a ticket.
    static func webURL(_ id: String?) -> URL? {
        let base = secret(webURLKey).flatMap(WhaTicketRules.normaliseBase)
            ?? (usesToken ? WhaTicketRules.cloudWeb : secret(urlKey).flatMap(WhaTicketRules.normaliseBase))
        guard let base else { return nil }
        if let id, (try? check(id)) != nil { return URL(string: "\(base)/tickets/\(id)") }
        return URL(string: "\(base)/tickets")
    }
}

// MARK: - Settings (UserDefaults; the credentials are in the Keychain)

enum WhaTicketSettings {
    static var autoAccept: Bool {
        get { UserDefaults.standard.bool(forKey: "whaticketAutoAccept") }
        set { UserDefaults.standard.set(newValue, forKey: "whaticketAutoAccept") }
    }
    /// Queue ids as text (whaticket.com uses UUIDs); numbers saved by an older build still load.
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

// MARK: - Poller

@MainActor
final class WhaTicketPoller {
    static let shared = WhaTicketPoller()
    private var timer: Timer?
    private var seenPending: Set<String>?
    private var unread: [String: Int] = [:]
    private var mineReady = false
    /// Tickets Coucou accepted on its own, for Undo (two minutes, self-hosted only).
    private var accepted: [String: Date] = [:]
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
            var (pending, mine) = try await WhaTicketAPI.fetch(account)

            var event: (label: String, detail: String?)?
            var acceptedNow = false

            // New tickets in the queue (the first poll only fills the card).
            let fresh = seenPending.map { seen in pending.filter { !seen.contains($0.id) } } ?? []
            seenPending = Set(pending.map(\.id))
            let minutes = Calendar.current.component(.hour, from: .now) * 60 + Calendar.current.component(.minute, from: .now)
            for t in fresh {
                let can = WhaTicketSettings.autoAccept && !DoNotDisturb.shared.isActive && !t.isGroup
                    && WhaTicketRules.queueAllowed(t.queueId, WhaTicketSettings.queues)
                    && WhaTicketRules.inHours(WhaTicketSettings.hours, minutes: minutes)
                if can {
                    do {
                        try await WhaTicketAPI.accept(t.id)
                        log.info("auto-accepted ticket \(t.id, privacy: .public)")
                        if !account.cloud { accepted[t.id] = .now }
                        acceptedNow = true
                        let detail = [t.queue, t.lastMessage].filter { !$0.isEmpty }.joined(separator: " · ")
                        event = (L("Accepted · \(t.name)"), detail.isEmpty ? nil : detail)
                        continue
                    } catch {
                        log.error("auto-accept \(t.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                event = (L("New ticket · \(t.name)"), t.lastMessage.isEmpty ? nil : t.lastMessage)
            }
            // Tickets accepted just now are mine already: list them on the card.
            if acceptedNow, let again = try? await WhaTicketAPI.fetch(account) {
                (pending, mine) = again
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
            accepted = accepted.filter { Date.now.timeIntervalSince($0.value) < 120 }

            state.whaticketUser = account.name
            state.whaticketPending = Array(pending.prefix(8))
            state.whaticketPendingCount = pending.count
            state.whaticketMine = Array(mine.prefix(8))
            state.whaticketMineCount = mine.count
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

    func accept(_ id: String) async throws {
        try await WhaTicketAPI.accept(id)
        log.info("accepted ticket \(id, privacy: .public)")
        await poll()
    }

    func undo(_ id: String) async throws {
        guard let at = accepted[id], Date.now.timeIntervalSince(at) < 120 else {
            throw WhaTicketAPI.Failure.message(L("Too late to undo — reopen it in WhaTicket."))
        }
        try await WhaTicketAPI.putBack(id)
        accepted[id] = nil
        log.info("undid ticket \(id, privacy: .public)")
        await poll()
    }
}
