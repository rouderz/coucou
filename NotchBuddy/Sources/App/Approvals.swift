import AppKit
import SwiftUI

// MARK: - Risk (#20)

/// How much a pending tool call can break: colours the approval and decides whether the
/// keyboard shortcut may approve it.
enum ApprovalRisk: Int, Sendable, Comparable {
    case low, medium, high

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var color: Color {
        switch self {
        case .low:    return Color(hex: "#22C55E")
        case .medium: return Color(hex: "#F5A524")
        case .high:   return Color(hex: "#F4505E")
        }
    }

    var title: String {
        switch self {
        case .low: return L("Low risk")
        case .medium: return L("Medium risk")
        case .high: return L("High risk")
        }
    }
}

enum ApprovalRiskClassifier {
    /// Returns the risk and a few words on why.
    static func classify(tool: String, input: [String: Any], cwd: String) -> (ApprovalRisk, String) {
        switch tool {
        case "Read", "Grep", "Glob", "LS", "WebSearch", "WebFetch", "TodoWrite":
            return (.low, L("read only"))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = (input["file_path"] ?? input["notebook_path"]) as? String ?? ""
            return classifyWrite(path: path, cwd: cwd)
        case "Bash":
            return classifyCommand(input["command"] as? String ?? "")
        default:
            if tool.hasPrefix("mcp__") { return (.medium, L("external tool")) }
            return (.medium, L("unknown tool"))
        }
    }

    private static func classifyWrite(path: String, cwd: String) -> (ApprovalRisk, String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sensitive = [".env", ".ssh/", ".aws/", ".gnupg/", "id_rsa", ".netrc", ".npmrc", ".zshrc", ".bashrc",
                         "/etc/", "/usr/", "/System/", "/Library/", "Keychains"]
        if sensitive.contains(where: { path.contains($0) }) { return (.high, L("sensitive file")) }
        if !cwd.isEmpty, !path.isEmpty, !path.hasPrefix(cwd + "/"), path.hasPrefix("/") {
            return (.high, path.hasPrefix(home) ? L("outside the project") : L("outside your home folder"))
        }
        return (.medium, L("changes a file"))
    }

    private static let high: [(String, String)] = [
        (#"\brm\s+(-[a-z]*[rf][a-z]*\s+)+"#, L("deletes files recursively")),
        (#"\bsudo\b"#, L("runs as administrator")),
        (#"\bgit\s+push\b.*(--force\b|-f\b|--force-with-lease)"#, L("force-pushes")),
        (#"\bgit\s+reset\s+--hard\b"#, L("discards changes")),
        (#"\bgit\s+clean\s+-[a-z]*f"#, L("deletes untracked files")),
        (#"\bgit\s+(branch\s+-d\b|checkout\s+--\s|restore\s)"#, L("discards work")),
        (#"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#, L("runs a downloaded script")),
        (#"\bchmod\s+(-r\s+)?777\b"#, L("opens permissions to everyone")),
        (#"\b(mkfs|diskutil\s+erase|dd\s+if=)"#, L("writes a disk")),
        (#">\s*/dev/(disk|sd)"#, L("writes a disk")),
        (#"\b(drop\s+(table|database)|truncate\s+table)\b"#, L("deletes data")),
        (#"\b(kubectl\s+delete|terraform\s+(destroy|apply)|docker\s+system\s+prune)\b"#, L("changes infrastructure")),
        (#"\b(npm|yarn|pnpm)\s+publish\b|\bgh\s+release\s+create\b"#, L("publishes")),
        (#"\b(killall|pkill|kill\s+-9)\b"#, L("kills processes")),
        (#"\bfind\b.*\s-(delete|exec\s+rm)\b"#, L("deletes files")),
    ]
    private static let medium: [(String, String)] = [
        (#"\b(npm|yarn|pnpm|bun)\s+(i|install|add|remove|uninstall)\b|\b(pip3?|brew|gem|cargo)\s+(install|uninstall)\b"#, L("installs packages")),
        (#"\bgit\s+(push|commit|merge|rebase|checkout|switch|tag|stash)\b"#, L("changes the repository")),
        (#"\b(rm|mv|cp|mkdir|touch|ln|chmod|chown)\b"#, L("changes files")),
        (#"(^|[^>2&])>{1,2}\s*[^&\s]"#, L("writes a file")),
        (#"\b(curl|wget|ssh|scp|rsync|nc)\b"#, L("uses the network")),
        (#"\b(docker|kubectl|terraform|gh|aws|gcloud|vercel)\b"#, L("talks to a service")),
    ]
    private static let readOnly = ["ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "pwd", "echo", "which",
                                   "file", "stat", "du", "df", "tree", "diff", "sort", "uniq", "jq", "env", "date",
                                   "whoami", "uname", "ps", "top", "sed", "awk"]

    static func classifyCommand(_ command: String) -> (ApprovalRisk, String) {
        let cmd = command.lowercased()
        for (pattern, why) in high where cmd.range(of: pattern, options: .regularExpression) != nil {
            return (.high, why)
        }
        if cmd.range(of: #"\bsed\s+-i"#, options: .regularExpression) != nil { return (.medium, L("edits files")) }
        for (pattern, why) in medium where cmd.range(of: pattern, options: .regularExpression) != nil {
            return (.medium, why)
        }
        if cmd.range(of: #"^\s*git\s+(status|diff|log|show|branch|remote|blame)\b"#, options: .regularExpression) != nil {
            return (.low, L("reads the repository"))
        }
        let first = cmd.split(whereSeparator: { " ;|&\n".contains($0) }).first.map(String.init) ?? ""
        if readOnly.contains(first) { return (.low, L("read only")) }
        if cmd.range(of: #"\b(npm|yarn|pnpm|bun)\s+(run\s+)?(test|lint|build|typecheck|check)\b|\b(swift|cargo|go)\s+(build|test)\b|\bxcodebuild\b"#,
                     options: .regularExpression) != nil {
            return (.low, L("builds or tests"))
        }
        return (.medium, L("runs a command"))
    }
}

// MARK: - "Always" rules in plain words (#21)

enum ApprovalRules {
    /// Claude Code's `permission_suggestions` → what "Always" would save, one line each.
    static func describe(_ suggestions: [[String: Any]]) -> [String] {
        suggestions.flatMap { s -> [String] in
            let place = destination(s["destination"] as? String)
            switch s["type"] as? String {
            case "addRules", "replaceRules":
                let behavior = s["behavior"] as? String ?? "allow"
                let rules = s["rules"] as? [[String: Any]] ?? []
                return rules.map { rule in
                    let tool = rule["toolName"] as? String ?? "?"
                    let content = rule["ruleContent"] as? String
                    let text = content.map { "\(tool)(\($0))" } ?? "every \(tool) call"
                    return "\(behavior == "allow" ? "Allow" : behavior.capitalized) \(text) · \(place)"
                }
            case "setMode":
                return ["Switch to \(s["mode"] as? String ?? "?") mode · \(place)"]
            case "addDirectories":
                let dirs = (s["directories"] as? [String] ?? []).map { ($0 as NSString).abbreviatingWithTildeInPath }
                return ["Allow access to \(dirs.joined(separator: ", ")) · \(place)"]
            default:
                return []
            }
        }
    }

    private static func destination(_ d: String?) -> String {
        switch d {
        case "localSettings":   return L("this project, only you")
        case "projectSettings": return L("this project, shared with the repo")
        case "userSettings":    return L("all your projects")
        case "session":         return L("this session")
        default:                return d ?? L("Claude Code settings")
        }
    }
}

// MARK: - Controls shared by the approval card and the live view

struct RiskChip: View {
    let risk: ApprovalRisk
    let reason: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(risk.color).frame(width: 6, height: 6)
            Text(reason.isEmpty ? risk.title : "\(risk.title) · \(reason)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(risk.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(risk.color.opacity(0.12))
        .clipShape(Capsule())
        .layoutPriority(-1)  // in a tight row, the chip shortens before the buttons do
        .help(reason.isEmpty ? risk.title : "\(risk.title) · \(reason)")
    }
}

/// Deny / Allow / Always…, with a confirmation step that shows the exact rule "Always" saves.
struct ApprovalControls: View {
    let approval: ApprovalInfo?
    /// Tight spaces (the live view bar): the shortcut hint moves to the buttons' tooltips.
    var compact: Bool = false
    @ObservedObject private var state = AppState.shared
    @State private var confirmingAlways = false

    var body: some View {
        Group {
            if confirmingAlways, let approval {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Saved for good:")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#8E939C"))
                        Text(approval.rules.joined(separator: "  ·  "))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(approval.rules.joined(separator: "\n"))
                    }
                    Spacer(minLength: 4)
                    SecondaryButton("Cancel") { confirmingAlways = false }
                    PrimaryButton("Save rule") { HookServer.shared.sendApprovalDecision("always") }
                }
            } else {
                HStack(spacing: 8) {
                    SecondaryButton("Deny") { HookServer.shared.sendApprovalDecision("deny") }
                        .help(state.approvalShortcutsEnabled ? "⌥⌫" : "")
                    PrimaryButton("Allow") { HookServer.shared.sendApprovalDecision("allow") }
                        .help(state.approvalShortcutsEnabled && approval?.risk != .high ? "⌥⏎" : "")
                    if let approval, !approval.rules.isEmpty {
                        SecondaryButton("Always…") { confirmingAlways = true }
                    }
                    if state.approvalShortcutsEnabled, !compact, let approval {
                        Text(approval.risk == .high ? "⌥⌫ deny" : "⌥⏎ allow · ⌥⌫ deny")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .id(approval?.id)  // a new request starts without the confirmation open
    }
}

// MARK: - Keyboard shortcuts (#28)

/// ⌥⏎ Allow · ⌥⌫ Deny, registered only while an approval is waiting so they never steal the
/// keys otherwise. High-risk calls can't be allowed from the keyboard: click Allow instead.
@MainActor
final class ApprovalShortcuts {
    static let shared = ApprovalShortcuts()

    private let allowKey = GlobalHotKey { HookServer.shared.sendApprovalDecision("allow") }
    private let denyKey = GlobalHotKey { HookServer.shared.sendApprovalDecision("deny") }
    private let option = NSEvent.ModifierFlags.option.rawValue

    func arm(for approval: ApprovalInfo) {
        disarm()
        guard AppState.shared.approvalShortcutsEnabled else { return }
        if approval.risk != .high { allowKey.register(keyCode: 36, flags: option) }  // ⌥⏎
        denyKey.register(keyCode: 51, flags: option)                                 // ⌥⌫
    }

    func disarm() {
        allowKey.unregister()
        denyKey.unregister()
    }
}
