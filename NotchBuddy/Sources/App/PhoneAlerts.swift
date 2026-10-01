import AppKit
import CoreGraphics
import os

/// Phone alerts for approvals nobody answered (#31), through ntfy (https://ntfy.sh): free iOS /
/// Android app, no account. Coucou posts to a random topic only you know; subscribe to it in the app.
/// Sends the project and the command, so the topic acts as a password: keep it private.
@MainActor
final class PhoneAlerts {
    static let shared = PhoneAlerts()
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")

    /// Seconds an approval waits before the phone is told.
    static let delay: TimeInterval = 20

    static func newTopic() -> String {
        "coucou-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
    }

    /// Called when an approval appears: alerts the phone if it's still waiting after `delay`
    /// and you're away (or always, if chosen).
    func approvalPending(_ approval: ApprovalInfo, project: String) {
        let state = AppState.shared
        guard state.phoneAlertsEnabled, !state.phoneAlertsTopic.isEmpty else { return }
        let id = approval.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, AppState.shared.pendingApproval?.id == id else { return }  // answered
                guard !AppState.shared.phoneAlertsOnlyWhenAway || Self.userIsAway else { return }
                self.send(title: L("Claude Code needs you · \(project)"),
                          message: "\(approval.tool): \(approval.command)",
                          priority: approval.risk == .high ? "urgent" : "high",
                          tags: approval.risk == .high ? "warning" : "robot")
            }
        }
    }

    /// Screen locked / asleep, or no keyboard or mouse for 2 minutes.
    static var userIsAway: Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return locked || idle > 120
    }

    func sendTest() {
        send(title: L("Coucou is connected"), message: L("You'll get approvals here when you're away from the Mac."),
             priority: "default", tags: "white_check_mark")
    }

    private func send(title: String, message: String, priority: String, tags: String) {
        let state = AppState.shared
        let server = state.phoneAlertsServer.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(server.isEmpty ? "https://ntfy.sh" : server)/\(state.phoneAlertsTopic)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = Data(String(message.prefix(400)).utf8)
        // Headers must be ASCII: ntfy accepts RFC 2047 for UTF-8 titles.
        req.setValue("=?UTF-8?B?\(Data(title.utf8).base64EncodedString())?=", forHTTPHeaderField: "Title")
        req.setValue(priority, forHTTPHeaderField: "Priority")
        req.setValue(tags, forHTTPHeaderField: "Tags")
        let log = self.log
        URLSession.shared.dataTask(with: req) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 { log.error("phone alert failed: HTTP \(code) \(error?.localizedDescription ?? "", privacy: .public)") }
        }.resume()
    }
}
