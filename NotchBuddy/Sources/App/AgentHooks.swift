import Foundation

/// Cursor CLI and Gemini CLI (#109): Coucou's answer in each agent's format, and the merge of
/// Coucou's hooks into ~/.cursor/hooks.json and ~/.gemini/settings.json. Pure functions (no I/O,
/// nothing is written here): the mirror of windows/src/claude/agents.ts, which has the tests and
/// the sources. Not wired to the relay or to Settings yet.
enum AgentHooks {
    enum Agent: String { case cursor, gemini }

    static let cursorEvents = [
        "sessionStart", "sessionEnd", "beforeSubmitPrompt", "beforeShellExecution",
        "beforeMCPExecution", "afterFileEdit", "postToolUse", "stop",
    ]
    static let geminiEvents = [
        "SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool", "Notification",
    ]

    /// What the relay prints for an answer from the island; nil means print nothing (the agent asks
    /// in its own UI). `hookEvent` is the agent's own event name. Never allows unless told to.
    static func answer(agent: Agent, hookEvent: String, decision: String) -> String? {
        let d = decision.trimmingCharacters(in: .whitespacesAndNewlines)
        switch agent {
        case .cursor:
            guard hookEvent == "beforeShellExecution" || hookEvent == "beforeMCPExecution" else { return nil }
            switch d {
            case "allow", "always": return #"{"permission":"allow"}"#
            case "ask": return #"{"permission":"ask"}"#
            case "deny":
                return #"{"permission":"deny","user_message":"Denied from Coucou","agent_message":"Denied from Coucou"}"#
            default: return nil
            }
        case .gemini:
            guard hookEvent == "BeforeTool" else { return nil }
            switch d {
            case "allow", "always": return #"{"decision":"allow"}"#
            case "deny": return #"{"decision":"deny","reason":"Denied from Coucou"}"#
            default: return nil // Gemini has no "ask": its own confirmation stays.
            }
        }
    }

    private static func isOurCommand(_ value: Any?) -> Bool {
        guard let command = value as? String else { return false }
        return command.contains("coucou-hook") || command.contains("nb-hook")
    }

    // Cursor: { "version": 1, "hooks": { event: [ { "command": ... } ] } }

    private static func cursorEntryIsOurs(_ entry: [String: Any]) -> Bool { isOurCommand(entry["command"]) }

    static func cursorInstalled(into root: [String: Any], command: String) -> [String: Any] {
        var root = root
        if root["version"] == nil { root["version"] = 1 }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in cursorEvents {
            var list = (hooks[event] as? [[String: Any]] ?? []).filter { !cursorEntryIsOurs($0) }
            list.append(["command": command])
            hooks[event] = list
        }
        root["hooks"] = hooks
        return root
    }

    static func cursorUninstalled(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for key in Array(hooks.keys) {
            guard let list = hooks[key] as? [[String: Any]] else { continue }
            let kept = list.filter { !cursorEntryIsOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    // Gemini: { "hooks": { Event: [ { "matcher"?: ..., "hooks": [ { type, command, name, timeout (ms) } ] } ] } }

    private static func geminiGroupIsOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { isOurCommand($0["command"]) } == true
    }

    static func geminiInstalled(into root: [String: Any], command: String) -> [String: Any] {
        var root = root
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in geminiEvents {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !geminiGroupIsOurs($0) }
            let timeout = event == "BeforeTool" ? 120_000 : 10_000
            groups.append(["hooks": [["type": "command", "command": command, "name": "coucou", "timeout": timeout]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    static func geminiUninstalled(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for key in Array(hooks.keys) {
            guard let groups = hooks[key] as? [[String: Any]] else { continue }
            let kept = groups.filter { !geminiGroupIsOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }
}
