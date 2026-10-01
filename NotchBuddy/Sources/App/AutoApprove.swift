import Foundation
import os

/// Per-project auto-approval (#29), built on the risk rating (#20). High risk always asks.
enum AutoApproveLevel: Int, CaseIterable, Identifiable, Sendable {
    case ask = 0, low = 1, medium = 2
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .ask: return L("Ask every time")
        case .low: return L("Auto-allow low risk")
        case .medium: return L("Auto-allow low and medium risk")
        }
    }

    func allows(_ risk: ApprovalRisk) -> Bool {
        switch self {
        case .ask: return false
        case .low: return risk == .low
        case .medium: return risk == .low || risk == .medium
        }
    }
}

@MainActor
enum AutoApprove {
    private static let key = "autoApproveRules"
    private static let log = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "claude")

    /// Project folder → level.
    static var rules: [String: AutoApproveLevel] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
            return raw.compactMapValues { AutoApproveLevel(rawValue: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.filter { $0.value != .ask }.mapValues(\.rawValue), forKey: key)
            AppState.shared.objectWillChange.send()
        }
    }

    static func set(_ level: AutoApproveLevel, for project: String) {
        var r = rules
        r[project] = level
        rules = r
    }

    /// The level for a request's folder: the most specific project rule that contains it.
    static func level(for cwd: String) -> AutoApproveLevel {
        rules.filter { cwd == $0.key || cwd.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }?.value ?? .ask
    }

    /// True when the request may go through without asking. Never for high risk, edits outside
    /// the project or Mochi's own chat.
    static func shouldAllow(risk: ApprovalRisk, cwd: String, fromChat: Bool) -> Bool {
        guard !fromChat, !cwd.isEmpty, risk != .high else { return false }
        let ok = level(for: cwd).allows(risk)
        if ok { log.info("auto-approved (\(risk.title, privacy: .public)) in \(cwd, privacy: .public)") }
        return ok
    }

    /// Projects to offer in Settings: those with a rule plus the sessions seen this run.
    static var knownProjects: [String] {
        let seen = AppState.shared.claudeSessions.map(\.cwd).filter { !$0.isEmpty }
        return Array(Set(rules.keys).union(seen)).sorted()
    }
}
