import Foundation
import os

/// Reads the Claude plan limits (5-hour and weekly) the same way claude.ai and Claude Code's
/// /usage do: Claude Code's OAuth token → `GET api.anthropic.com/api/oauth/usage`.
///
/// Works with no Claude Code session open and for Mochi's own chat. The token is read with
/// `/usr/bin/security`, so macOS asks once ("Always Allow") instead of after every Debug build.
/// The token is never refreshed or stored by Coucou: when it expires, the next `claude` run renews it.
final class PlanUsagePoller: @unchecked Sendable {
    static let shared = PlanUsagePoller()
    private var timer: DispatchSourceTimer?
    /// Set when the user denied keychain access: stop asking until a manual refresh.
    private var keychainDenied = false
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")
    private init() {}

    func start() {
        #if !APPSTORE
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 3, repeating: 120)
        t.setEventHandler { [weak self] in self?.poll(manual: false) }
        t.resume()
        timer = t
        #endif
    }

    func pollNow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.poll(manual: true) }
    }

    // MARK: - Poll

    private func poll(manual: Bool) {
        if manual { keychainDenied = false }
        guard !keychainDenied, let creds = readCredentials() else { return }
        if let expires = creds.expiresAt, expires < Date() {
            log.info("plan usage: Claude Code token expired, waiting for the next claude run")
            return
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [log] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.error("plan usage: HTTP \(status) \(error?.localizedDescription ?? "", privacy: .public)")
                return
            }
            let five = Self.window(json["five_hour"])
            let week = Self.window(json["seven_day"])
            let plan = creds.plan
            Task { @MainActor in
                var usage = AppState.shared.planUsage ?? PlanUsage()
                usage.fiveHour = five
                usage.sevenDay = week
                if let plan { usage.plan = plan }
                usage.updatedAt = .now
                AppState.shared.planUsage = usage
            }
        }.resume()
    }

    /// `{"utilization": 81.0, "resets_at": "2026-10-01T18:00:00.123456+00:00"}` → Window
    private static func window(_ any: Any?) -> PlanUsage.Window? {
        guard let w = any as? [String: Any],
              let pct = (w["utilization"] as? NSNumber)?.doubleValue,
              let raw = w["resets_at"] as? String,
              let date = parseDate(raw) else { return nil }
        return PlanUsage.Window(percent: pct, resetsAt: date)
    }

    private static func parseDate(_ raw: String) -> Date? {
        // ISO8601DateFormatter rejects microseconds: drop the fraction first.
        let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    // MARK: - Claude Code credentials

    private struct Credentials { let token: String; let expiresAt: Date?; let plan: String? }

    private func readCredentials() -> Credentials? {
        var data: Data?
        // 1. macOS keychain (where Claude Code keeps its login).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            let bytes = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                data = bytes
            } else if p.terminationStatus != 44 {  // 44 = item not found; anything else = denied/cancelled
                keychainDenied = true
                log.error("plan usage: keychain access refused (\(p.terminationStatus))")
            }
        }
        // 2. Older / Linux-style installs keep it in a file.
        if data == nil {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            data = try? Data(contentsOf: file)
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let plan = (oauth["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return Credentials(token: token, expiresAt: expires, plan: plan)
    }
}
