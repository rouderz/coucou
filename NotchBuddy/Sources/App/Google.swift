import AppKit
import CryptoKit
import Darwin
import os
import Security

// Google Workspace: Gmail in the island, Google Drive files in the chat. Same behaviour as
// windows/src-tauri/src/google.rs.
//
// OAuth 2.0 for desktop apps with the user's own Google Cloud client (Gmail scopes are
// "restricted", so a client shipped inside Coucou would need Google's verification): the
// browser opens Google's consent page, Google redirects to http://127.0.0.1:<port> where Coucou
// waits for that one request, and the code is exchanged with PKCE (S256). The refresh token is
// kept in the Keychain; access tokens only in memory. Read-only scopes: Coucou never sends
// mail or changes a file, and only talks to Google's APIs.

struct GmailMessage: Identifiable, Equatable, Sendable {
    let id: String
    let threadId: String
    let from: String
    let subject: String
    let snippet: String
    let date: Date?
}

struct DriveFile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let modified: String
}

enum GoogleFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Pure helpers (tested in GoogleTests)

enum GoogleText {
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? s
    }

    /// `code`, `state` and `error` from "GET /?state=…&code=… HTTP/1.1".
    static func parseRedirect(_ request: String) -> (code: String?, state: String?, error: String?)? {
        guard let line = request.components(separatedBy: "\r\n").first ?? request.components(separatedBy: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        guard let comps = URLComponents(string: "http://127.0.0.1" + String(parts[1])) else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return (value("code"), value("state"), value("error"))
    }

    /// "\"Ana Pérez\" <ana@x.com>" → "Ana Pérez".
    static func senderName(_ from: String) -> String {
        let name = (from.components(separatedBy: "<").first ?? from)
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? from.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) : name
    }

    static func header(_ message: [String: Any], _ name: String) -> String {
        let headers = (message["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        return headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String ?? ""
    }

    /// The text of a message (format=full): the first text/plain part, else text/html stripped.
    static func messageText(_ payload: [String: Any]) -> String {
        func find(_ part: [String: Any], _ mime: String) -> String? {
            if part["mimeType"] as? String == mime,
               let data = (part["body"] as? [String: Any])?["data"] as? String,
               let bytes = decodeBase64url(data) {
                return String(decoding: bytes, as: UTF8.self)
            }
            for p in part["parts"] as? [[String: Any]] ?? [] {
                if let found = find(p, mime) { return found }
            }
            return nil
        }
        if let text = find(payload, "text/plain") { return text }
        let html = find(payload, "text/html") ?? ""
        var out = "", inTag = false
        for c in html {
            if c == "<" { inTag = true } else if c == ">" { inTag = false; out.append(" ") } else if !inTag { out.append(c) }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Google Docs / Sheets / Slides → (export type, extension); nil for ordinary files.
    static func exportType(_ mime: String) -> (String, String)? {
        switch mime {
        case "application/vnd.google-apps.document": return ("text/plain", "txt")
        case "application/vnd.google-apps.spreadsheet": return ("text/csv", "csv")
        case "application/vnd.google-apps.presentation": return ("text/plain", "txt")
        default: return nil
        }
    }

    static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_().,"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(80))
    }
}

// MARK: - The one-request server Google redirects to

enum LoopbackServer {
    /// Binds 127.0.0.1 on a free port.
    static func open() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GoogleFailure.message(L("Couldn't open a local port for the sign-in.")) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw GoogleFailure.message(L("Couldn't open a local port for the sign-in."))
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    /// Waits for the request carrying `code` or `error` (skipping /favicon.ico), answers it
    /// with a small page, and returns it. Blocking: run it off the main thread.
    static func waitForRedirect(fd: Int32, seconds: Int, expectedState: String) throws -> String {
        defer { close(fd) }
        let deadline = Date.now.addingTimeInterval(TimeInterval(seconds))
        while true {
            let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard left > 0, poll(&pfd, 1, left) > 0 else {
                throw GoogleFailure.message(L("Nobody finished signing in within 5 minutes."))
            }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            // Browsers open idle "preconnect" sockets: don't let one hold up the real redirect.
            var cpfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&cpfd, 1, 5000) > 0 else { close(client); continue }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(client, &buffer, buffer.count)
            let request = String(decoding: buffer.prefix(max(0, n)), as: UTF8.self)
            guard let parsed = GoogleText.parseRedirect(request), parsed.code != nil || parsed.error != nil else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = notFound.withCString { write(client, $0, strlen($0)) }
                close(client)
                continue
            }
            let ok = parsed.error == nil && parsed.state == expectedState
            let body = ok
                ? "<html><body style='font-family:-apple-system;padding:40px'><h2>Coucou is connected to Google.</h2>You can close this tab.</body></html>"
                : "<html><body style='font-family:-apple-system;padding:40px'><h2>Google sign-in didn't finish.</h2>Go back to Coucou and try again.</body></html>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = reply.withCString { write(client, $0, strlen($0)) }
            close(client)
            return request
        }
    }
}

// MARK: - API

@MainActor
enum GoogleAPI {
    static let clientIDKey = "google-client-id"
    static let clientSecretKey = "google-client-secret"
    static let refreshKey = "google-refresh-token"
    private static let scopes = "openid email https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/drive.readonly"

    private static var accessToken: String?
    private static var accessUntil = Date.distantPast

    typealias Failure = GoogleFailure

    static var hasClient: Bool { !(Secrets.store.get(clientIDKey) ?? "").isEmpty }
    static var isConnected: Bool { hasClient && !(Secrets.store.get(refreshKey) ?? "").isEmpty }

    private static func randomString(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return GoogleText.base64url(data)
    }

    /// Opens Google's consent page and waits for the answer; returns the account's email.
    static func connect() async throws -> String {
        guard let clientID = Secrets.store.get(clientIDKey), !clientID.isEmpty else {
            throw Failure.message(L("Paste your Google OAuth client ID first (see the steps above)."))
        }
        let secret = Secrets.store.get(clientSecretKey) ?? ""
        let (fd, port) = try LoopbackServer.open()
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = randomString(32)
        let state = randomString(16)
        let url = "https://accounts.google.com/o/oauth2/v2/auth?client_id=\(GoogleText.encode(clientID))"
            + "&redirect_uri=\(GoogleText.encode(redirect))&response_type=code&scope=\(GoogleText.encode(scopes))"
            + "&code_challenge=\(GoogleText.challenge(for: verifier))&code_challenge_method=S256"
            + "&state=\(state)&access_type=offline&prompt=consent"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }

        let request = try await Task.detached {
            try LoopbackServer.waitForRedirect(fd: fd, seconds: 300, expectedState: state)
        }.value
        guard let parsed = GoogleText.parseRedirect(request) else { throw Failure.message(L("No code from Google")) }
        if let error = parsed.error { throw Failure.message(L("Google said: \(error)")) }
        guard parsed.state == state, let code = parsed.code else {
            throw Failure.message(L("The answer from Google didn't match this sign-in."))
        }
        let json = try await tokenRequest([
            "code": code, "client_id": clientID, "client_secret": secret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw Failure.message(L("Google sent no refresh token")) }
        Secrets.store.set(refreshKey, value: refresh)
        remember(json)
        let profile = try? await getJSON("https://gmail.googleapis.com/gmail/v1/users/me/profile")
        let email = profile?["emailAddress"] as? String ?? ""
        UserDefaults.standard.set(email, forKey: "googleEmail")
        return email
    }

    static func disconnect() async {
        if let refresh = Secrets.store.get(refreshKey), let url = URL(string: "https://oauth2.googleapis.com/revoke") {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("token=\(GoogleText.encode(refresh))".utf8)
            _ = try? await URLSession.shared.data(for: req)
        }
        Secrets.store.remove(refreshKey)
        accessToken = nil
        UserDefaults.standard.removeObject(forKey: "googleEmail")
    }

    private static func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { throw Failure.message("") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(fields.map { "\($0.key)=\(GoogleText.encode($0.value))" }.joined(separator: "&").utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw Failure.message(L("Can't reach Google")) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200 else {
            let why = json["error_description"] as? String ?? json["error"] as? String ?? ""
            throw Failure.message(L("Google refused the sign-in (\(code)) \(why)"))
        }
        return json
    }

    private static func remember(_ json: [String: Any]) {
        guard let token = json["access_token"] as? String else { return }
        accessToken = token
        accessUntil = Date.now.addingTimeInterval(TimeInterval((json["expires_in"] as? Int ?? 3600) - 60))
    }

    private static func token() async throws -> String {
        if let accessToken, Date.now < accessUntil { return accessToken }
        guard let refresh = Secrets.store.get(refreshKey), let clientID = Secrets.store.get(clientIDKey) else {
            throw Failure.message(L("Not connected to Google"))
        }
        let json = try await tokenRequest([
            "client_id": clientID, "client_secret": Secrets.store.get(clientSecretKey) ?? "",
            "refresh_token": refresh, "grant_type": "refresh_token",
        ])
        remember(json)
        guard let accessToken else { throw Failure.message(L("Not connected to Google")) }
        return accessToken
    }

    static func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw Failure.message("Bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw Failure.message(L("Can't reach Google")) }
        PollGate.shared.record("integration_gmail", response)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 401:
            accessToken = nil
            throw Failure.message(L("Google signed Coucou out — connect again in Settings"))
        case 403: throw Failure.message(L("Google refused (403): is the Gmail / Drive API turned on in your Google Cloud project?"))
        case let code: throw Failure.message(L("Google error \(code)"))
        }
    }

    static func getJSON(_ url: String) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await get(url))) as? [String: Any] ?? [:]
    }

    // MARK: Gmail

    static var gmailQuery: String {
        let q = UserDefaults.standard.string(forKey: "gmailQuery") ?? ""
        return q.trimmingCharacters(in: .whitespaces).isEmpty ? "is:unread in:inbox" : q
    }

    static func inbox() async throws -> (mails: [GmailMessage], total: Int) {
        let list = try await getJSON("https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=10&q=\(GoogleText.encode(gmailQuery))")
        let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        var mails: [GmailMessage] = []
        for id in ids.prefix(5) {
            guard let m = try? await getJSON("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject") else { continue }
            let millis = (m["internalDate"] as? String).flatMap(Double.init)
            mails.append(GmailMessage(id: id, threadId: m["threadId"] as? String ?? id,
                                      from: GoogleText.senderName(GoogleText.header(m, "From")),
                                      subject: GoogleText.header(m, "Subject"),
                                      snippet: m["snippet"] as? String ?? "",
                                      date: millis.map { Date(timeIntervalSince1970: $0 / 1000) }))
        }
        return (mails, list["resultSizeEstimate"] as? Int ?? mails.count)
    }

    /// A mail saved as a text file in the inbox folder, to attach to the chat.
    static func mailFile(_ id: String) async throws -> URL {
        guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw Failure.message("Unknown mail") }
        let m = try await getJSON("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")
        let subject = GoogleText.header(m, "Subject")
        let text = "From: \(GoogleText.header(m, "From"))\nTo: \(GoogleText.header(m, "To"))\nDate: \(GoogleText.header(m, "Date"))\nSubject: \(subject)\n\n"
            + GoogleText.messageText(m["payload"] as? [String: Any] ?? [:])
        return try save(Data(text.utf8), name: "Mail - \(subject.isEmpty ? "no subject" : subject)", ext: "txt")
    }

    // MARK: Drive

    static func driveSearch(_ text: String) async throws -> [DriveFile] {
        let escaped = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let q = escaped.isEmpty ? "trashed = false" : "name contains '\(escaped)' and trashed = false"
        let json = try await getJSON("https://www.googleapis.com/drive/v3/files?pageSize=8&orderBy=modifiedTime%20desc"
            + "&fields=files(id,name,mimeType,modifiedTime)&q=\(GoogleText.encode(q))")
        return (json["files"] as? [[String: Any]] ?? []).compactMap { f in
            guard let id = f["id"] as? String else { return nil }
            return DriveFile(id: id, name: f["name"] as? String ?? "", mimeType: f["mimeType"] as? String ?? "",
                             modified: f["modifiedTime"] as? String ?? "")
        }
    }

    /// Downloads a Drive file into the inbox folder (Docs / Sheets / Slides exported as text / CSV).
    static func driveFile(_ file: DriveFile) async throws -> URL {
        guard file.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw Failure.message("Unknown file")
        }
        if let export = GoogleText.exportType(file.mimeType) {
            let data = try await get("https://www.googleapis.com/drive/v3/files/\(file.id)/export?mimeType=\(GoogleText.encode(export.0))")
            return try save(data, name: file.name, ext: export.1)
        }
        guard !file.mimeType.hasPrefix("application/vnd.google-apps") else {
            throw Failure.message(L("Coucou can read Docs, Sheets, Slides and ordinary files — not this kind."))
        }
        let data = try await get("https://www.googleapis.com/drive/v3/files/\(file.id)?alt=media")
        let ext = (file.name as NSString).pathExtension
        return try save(data, name: (file.name as NSString).deletingPathExtension, ext: ext.isEmpty ? "bin" : ext)
    }

    private static func save(_ data: Data, name: String, ext: String) throws -> URL {
        guard data.count <= 10 * 1024 * 1024 else { throw Failure.message(L("That file is over 10 MB — too big for the chat.")) }
        let inbox = HookServer.supportDir.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let base = GoogleText.safeFileName(name)
        let cleanExt = String(ext.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        var url = inbox.appendingPathComponent("\(base).\(cleanExt)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = inbox.appendingPathComponent("\(base) (\(i)).\(cleanExt)")
            i += 1
        }
        try data.write(to: url)
        return url
    }

    /// Puts a file in the chat; it goes with the next question.
    static func attach(_ url: URL, fresh: Bool) {
        let state = AppState.shared
        if fresh { ChatSession.startNew(state) }
        state.droppedFile = DroppedFile(url: url, name: url.lastPathComponent)
        state.promptContext = .file(name: url.lastPathComponent, fileURL: url)
        state.view = .prompt
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.prompt)
    }
}

// MARK: - Gmail poller

@MainActor
final class GmailPoller {
    static let shared = GmailPoller()
    static let id = "integration_gmail"
    private var timer: Timer?
    private var seen: Set<String>?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard PollGate.shared.allow(GmailPoller.id, every: 60) else { return }
                GmailPoller.shared.pollNow()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) { GmailPoller.shared.pollNow() }
    }

    func reset() { seen = nil }

    func pollNow() {
        guard GoogleAPI.isConnected, AppState.shared.activeIntegrations.contains(Self.id) else { return }
        Task { @MainActor in
            let state = AppState.shared
            do {
                let (mails, total) = try await GoogleAPI.inbox()
                let fresh = seen.map { old in mails.first { !old.contains($0.id) } } ?? nil
                seen = Set(mails.map(\.id))
                state.gmailMails = mails
                state.gmailTotal = total
                state.gmailError = nil
                state.gmailLoaded = true
                if let fresh { announce(fresh) }
            } catch {
                state.gmailError = error.localizedDescription
                state.gmailLoaded = true
            }
        }
    }

    private func announce(_ mail: GmailMessage) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.id }) else { return }
        state.tasks[idx].state = .finished
        state.tasks[idx].steps = mail.subject.isEmpty ? [L("Mail · \(mail.from)")] : [L("Mail · \(mail.from)"), mail.subject]
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
}
