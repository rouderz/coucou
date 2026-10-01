import AppKit
import os

/// What the Coucou editor extension (VS Code, Cursor, Windsurf, VSCodium…) last reported (#58).
struct EditorReport: Sendable {
    let appName: String          // vscode.env.appName: "Visual Studio Code", "Cursor"…
    let file: String
    let workspace: String?
    let language: String?
    let cursorLine: Int?
    let selection: String?
    let problems: [String]
    let receivedAt: Date
}

/// Receives `EditorContext` / `EditorAsk` messages from the extension over Coucou's socket and
/// turns them into the chat's code context. More precise than Accessibility: exact file, cursor,
/// selection and the editor's diagnostics.
@MainActor
final class EditorBridge {
    static let shared = EditorBridge()
    private(set) var last: EditorReport?
    private let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "assistant")
    /// Reports older than this are ignored (the editor may have been closed).
    private let freshness: TimeInterval = 15 * 60

    /// `EditorContext` (sent on every editor / selection change) and `EditorAsk` (the
    /// extension's "Ask Mochi" command: opens the chat with this context).
    func handle(event: String, payload: [String: Any]) {
        guard let file = payload["file"] as? String, file.hasPrefix("/") else { return }
        let problems = (payload["diagnostics"] as? [[String: Any]] ?? []).prefix(20).map { d -> String in
            let line = d["line"] as? Int ?? 0
            let severity = d["severity"] as? String ?? "problem"
            let source = (d["source"] as? String).map { " (\($0))" } ?? ""
            return "line \(line) · \(severity)\(source): \(d["message"] as? String ?? "")"
        }
        let selection = (payload["selection"] as? String)
            .map { $0.count > 8_000 ? String($0.prefix(8_000)) + "\n…" : $0 }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        last = EditorReport(appName: payload["appName"] as? String ?? "Editor", file: file,
                            workspace: payload["workspace"] as? String, language: payload["language"] as? String,
                            cursorLine: payload["line"] as? Int, selection: selection,
                            problems: Array(problems), receivedAt: .now)

        if event == "EditorAsk", let context = codeContext() {
            log.info("ask: from the editor extension (\(context.fileName, privacy: .public))")
            NotificationCenter.default.post(name: .askWithEditorContext, object: nil,
                                            userInfo: ["context": context])
        }
    }

    /// The extension's report, if it's fresh and comes from the app in front.
    func context(for app: NSRunningApplication) -> CodeContext? {
        guard let report = last, Date.now.timeIntervalSince(report.receivedAt) < freshness else { return nil }
        let name = app.localizedName?.lowercased() ?? ""
        let reported = report.appName.lowercased()
        let sameApp = name == reported || reported.contains(name) || name.contains(reported)
            || (reported.contains("visual studio code") && (app.bundleIdentifier ?? "").hasPrefix("com.microsoft.VSCode"))
        return sameApp ? codeContext() : nil
    }

    private func codeContext() -> CodeContext? {
        guard let report = last else { return nil }
        let session = AppState.shared.tasks.first { $0.id == "integration_claude" }?.sessionCwd
        let project = report.workspace.flatMap { report.file.hasPrefix($0 + "/") ? $0 : nil }
            ?? CodeContextCapture.projectRoot(for: report.file, sessionFolder: session)
        return CodeContext(appName: report.appName, file: report.file, project: project,
                           selection: report.selection, cursorLine: report.cursorLine,
                           problems: report.problems.isEmpty ? nil : report.problems)
    }
}

extension Notification.Name {
    static let askWithEditorContext = Notification.Name("notchBuddy.askWithEditorContext")
}
