import Foundation

// MARK: - Codex CLI (#44)
// Codex runs Claude Code–style hooks (same events, same JSON on stdin, same decisions on stdout),
// so the same nb-hook relay serves both; it tags Codex events with "agent": "codex".

/// Codex's `apply_patch` tool: the patch text, the files it touches, and a diff for the live view.
enum CodexPatch {
    struct FileChange: Equatable {
        enum Kind: Equatable { case update, add, delete }
        var path: String
        var kind: Kind
        var lines: [EditPreview.Line] = []
    }

    /// The patch carried by a tool_input, whichever key Codex used for it.
    static func text(from input: [String: Any]) -> String? {
        for key in ["command", "patch", "input"] {
            if let s = input[key] as? String, s.contains("*** Begin Patch") { return s }
            if let list = input[key] as? [String], let s = list.first(where: { $0.contains("*** Begin Patch") }) { return s }
        }
        return nil
    }

    static func parse(_ patch: String) -> [FileChange] {
        var changes: [FileChange] = []
        for raw in patch.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let path = header(line, "*** Update File: ") {
                changes.append(FileChange(path: path, kind: .update))
            } else if let path = header(line, "*** Add File: ") {
                changes.append(FileChange(path: path, kind: .add))
            } else if let path = header(line, "*** Delete File: ") {
                changes.append(FileChange(path: path, kind: .delete))
            } else if let path = header(line, "*** Move to: "), !changes.isEmpty {
                changes[changes.count - 1].path = path
            } else if line.hasPrefix("***") || changes.isEmpty {
                continue
            } else if line.hasPrefix("@@") {
                if !changes[changes.count - 1].lines.isEmpty {
                    changes[changes.count - 1].lines.append(.init(kind: .context, number: nil, text: "⋯"))
                }
            } else if line.hasPrefix("+") {
                changes[changes.count - 1].lines.append(.init(kind: .added, number: nil, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                changes[changes.count - 1].lines.append(.init(kind: .removed, number: nil, text: String(line.dropFirst())))
            } else if line.hasPrefix(" ") {
                changes[changes.count - 1].lines.append(.init(kind: .context, number: nil, text: String(line.dropFirst())))
            }
        }
        return changes
    }

    /// Paths in the patch, made absolute against the session's folder.
    static func files(_ patch: String, cwd: String) -> [String] {
        parse(patch).map { absolute($0.path, cwd: cwd) }
    }

    /// The first file's change as a live-view diff; the note says what else the patch does.
    static func preview(_ patch: String, cwd: String) -> EditPreview? {
        let changes = parse(patch)
        guard let first = changes.first else { return nil }
        let file = absolute(first.path, cwd: cwd)
        var notes: [String] = []
        switch first.kind {
        case .add: notes.append(L("new file"))
        case .delete: notes.append(L("deletes the file"))
        case .update: break
        }
        if changes.count == 2 { notes.append(L("+1 more file")) }
        if changes.count > 2 { notes.append(L("+\(changes.count - 1) more files")) }
        return EditPreview(file: file, relativePath: first.path, language: CodeLanguage(path: file),
                           lines: Array(first.lines.prefix(400)),
                           note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    private static func header(_ line: String, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func absolute(_ path: String, cwd: String) -> String {
        path.hasPrefix("/") || cwd.isEmpty ? path : (cwd as NSString).appendingPathComponent(path)
    }
}

#if !APPSTORE
/// Installs Coucou's hooks in ~/.codex/hooks.json (Codex asks the user to trust them with /hooks).
enum CodexHooks {
    enum State: Equatable { case noCodex, notInstalled, installed }

    static var codexDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
    static var hooksURL: URL { codexDir.appendingPathComponent("hooks.json") }

    /// Codex events Coucou listens to, with their timeouts (seconds).
    static let events: [(String, Int)] = [
        ("SessionStart", 10), ("SessionEnd", 10),
        ("UserPromptSubmit", 10),
        ("PreToolUse", 10), ("PostToolUse", 10),
        ("PermissionRequest", 120),
        ("Stop", 10),
        ("SubagentStart", 10), ("SubagentStop", 10),
    ]

    static var command: String {
        "\"\(HookServer.hookScriptPath.replacingOccurrences(of: "\"", with: "\\\""))\" --agent codex"
    }

    static func state() -> State {
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return .noCodex }
        guard let data = try? Data(contentsOf: hooksURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        return hooks.values.contains { isOurs($0) } ? .installed : .notInstalled
    }

    /// hooks.json with Coucou's hooks added (the user's own hooks are kept).
    static func installed(into root: [String: Any], command: String) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs([$0]) }
            groups.append(["hooks": [["type": "command", "command": command, "timeout": timeout,
                                      "statusMessage": "Coucou"]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    /// hooks.json without Coucou's hooks.
    static func uninstalled(from root: [String: Any]) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for key in hooks.keys {
            let groups = (hooks[key] as? [[String: Any]] ?? []).filter { !isOurs([$0]) }
            if groups.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    static func install() throws {
        HookServer.shared.installHookScript()
        try write(installed(into: read(), command: command), backup: true)
    }

    static func uninstall() throws {
        try write(uninstalled(from: read()), backup: false)
    }

    private static func isOurs(_ groups: Any) -> Bool {
        (groups as? [[String: Any]])?.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("nb-hook") == true
            } == true
        } == true
    }

    private static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }

    private static func write(_ root: [String: Any], backup: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        if backup, fm.fileExists(atPath: hooksURL.path) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
            try? fm.copyItem(at: hooksURL, to: codexDir.appendingPathComponent("hooks.json.bak-\(f.string(from: .now))"))
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }
}
#endif
