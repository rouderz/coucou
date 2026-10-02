import Foundation

final class ResendPoller: @unchecked Sendable {
    static let shared = ResendPoller()
    private var timer: DispatchSourceTimer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 6, repeating: 60)
        t.setEventHandler { [weak self] in
            guard PollGate.shared.allow("integration_resend", every: 60) else { return }
            self?.poll()
        }
        t.resume()
        timer = t
    }

    /// Polls right away (refresh button, keys just saved).
    func pollNow() { DispatchQueue.global(qos: .utility).async { [weak self] in self?.poll() } }

    private func poll() {
        guard let apiKey = Secrets.store.get("resend-api-key") else { return }
        guard let url = URL(string: "https://api.resend.com/emails?limit=100") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            PollGate.shared.record("integration_resend", response)
            guard let data, code == 200 else {
                IntegrationStatus.report("integration_resend",
                                         .error(IntegrationStatus.httpError("Resend", code: code, error: error)))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawList = json["data"] as? [[String: Any]] else {
                IntegrationStatus.report("integration_resend", .error("Unexpected response from Resend"))
                return
            }
            IntegrationStatus.report("integration_resend", rawList.isEmpty ? .empty(L("Connected · no emails sent yet")) : .ok)

            let total = (json["total"] as? Int) ?? (json["count"] as? Int)
            let emails = rawList.compactMap { Self.parseEmail($0) }

            DispatchQueue.main.async {
                AppState.shared.resendEmails = Array(emails.prefix(5))
                AppState.shared.resendTotal  = total ?? (emails.isEmpty ? nil : emails.count)
            }
        }.resume()
    }

    static func parseEmail(_ d: [String: Any]) -> ResendEmail? {
        guard let id        = d["id"]         as? String,
              let createdAt = d["created_at"] as? String else { return nil }

        let to: [String]
        if let arr = d["to"] as? [String] { to = arr }
        else if let single = d["to"] as? String { to = [single] }
        else { to = [] }

        let subject   = (d["subject"]    as? String) ?? ""
        let lastEvent = (d["last_event"] as? String) ?? ""

        // Parse ISO8601 date
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: createdAt)
                ?? ISO8601DateFormatter().date(from: createdAt)
                ?? Date()

        return ResendEmail(id: id, to: to, subject: subject, createdAt: date, lastEvent: lastEvent)
    }

    // MARK: - Sending (#16: no network calls from views)

    /// Sends one email (with the dropped file attached, if any). Only after the user's click.
    static func sendEmail(apiKey: String, from: String, to: String,
                          subject: String, body: String, fileURL: URL?) async -> Bool {
        guard let url = URL(string: "https://api.resend.com/emails") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "from": from,
            "to": [to],
            "subject": subject,
            "text": body.isEmpty ? " " : body
        ]
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            payload["attachments"] = [[
                "filename": fileURL.lastPathComponent,
                "content": data.base64EncodedString()
            ]]
        }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        request.httpBody = httpBody
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 || code == 201 { return true }
        // Surface Resend error body for debugging
        if let body = String(data: data, encoding: .utf8) {
            print("[Resend] HTTP \(code): \(body)")
        }
        return false
    }
}
