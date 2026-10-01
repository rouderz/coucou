import Foundation
import SwiftUI

// MARK: - Island Mode

enum IslandMode: String, CaseIterable {
    case hidden, compact, expanded
}

// MARK: - Island View

enum IslandView: String, CaseIterable {
    case overview, empty, approval, question, error, finished
    case confused, upload, uploading, choose, mail, prompt
    case searching, result, note, settings, greeting
    case live      // what Claude Code is doing right now: file, diff and steps
    case inbox     // reviews, mentions and assignments from GitHub and Linear
}

// MARK: - Bot State

enum BotState: String, CaseIterable {
    case idle, working, thinking, searching
    case approval, question, error, finished
    case ratelimit, sleeping, dizzy
}

// MARK: - Bot Emote

enum BotEmote: String, CaseIterable {
    case love, surprised, proud, wink, yawn, happy, annoyed
}

// MARK: - Approval info (pending PermissionRequest from Claude Code)

struct ApprovalInfo: Sendable {
    let id = UUID()
    var sessionId: String
    var tool: String
    var command: String
    var risk: ApprovalRisk = .medium
    var riskReason: String = ""
    /// What "Always" would save, in plain words (from Claude Code's permission_suggestions).
    var rules: [String] = []
    /// The session's folder, for per-project auto-approval (#29).
    var cwd: String = ""
}

// MARK: - Pill badge (shown on pill edge when non-focused task has an alert)

enum PillBadge { case approval, finished, error }

// MARK: - Agent Task

struct AgentTask: Identifiable, Equatable {
    var id: String
    var name: String
    var color: String          // hex
    var state: BotState
    var stepIndex: Int = 0
    var steps: [String]
    var source: AgentSource
    var isIntegration: Bool = false  // true for persistent integration pills
    var emote: BotEmote? = nil
    var miniEye: EyeShape? = nil
    var pillBadge: PillBadge? = nil  // alert badge shown on pill when not focused
    var sessionCwd: String?  = nil  // last known working directory (Claude Code sessions)
}

enum AgentSource: Equatable {
    case claudeCode
    case n8n
}

// MARK: - View dimensions (from VIEWS in prototype)

struct ViewLayout {
    let height: CGFloat
    let botX: CGFloat
    let botY: CGFloat?         // nil = auto-centered
    let botDiameter: CGFloat
    let agentMode: AgentLayoutMode
}

enum AgentLayoutMode {
    case none, grid, pills, column
}

// MARK: - Constants (from NW, NH, EW in prototype)

enum IslandConst {
    static let notchWidth: CGFloat  = 184
    static let notchHeight: CGFloat = 32
    static let expandedWidth: CGFloat = 640
    static let earRadius: CGFloat   = 14
    static let roundedCorner: CGFloat = 14    // hidden/peek/compact
    static let expandedCorner: CGFloat = 22

    static let viewLayouts: [IslandView: ViewLayout] = [
        // Home is the reference: height 150
        .overview:  ViewLayout(height: 160, botX: 68,  botY: nil, botDiameter: 58, agentMode: .pills),
        // All non-chat views match home height (150) — law
        .empty:     ViewLayout(height: 160, botX: 70,  botY: nil, botDiameter: 62, agentMode: .none),
        .approval:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 56, agentMode: .column),
        .question:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 56, agentMode: .column),
        .error:     ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 58, agentMode: .column),
        .finished:  ViewLayout(height: 160, botX: 62,  botY: nil, botDiameter: 58, agentMode: .column),
        .confused:  ViewLayout(height: 160, botX: 76,  botY: nil, botDiameter: 66, agentMode: .column),
        .upload:    ViewLayout(height: 176, botX: 140, botY: 104, botDiameter: 62, agentMode: .column),
        .uploading: ViewLayout(height: 176, botX: 46,  botY: 118, botDiameter: 20, agentMode: .none),
        .choose:    ViewLayout(height: 176, botX: 60,  botY: 101, botDiameter: 52, agentMode: .column),
        .mail:      ViewLayout(height: 240, botX: 56,  botY: nil, botDiameter: 46, agentMode: .column),
        .prompt:    ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .searching: ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .result:    ViewLayout(height: 160, botX: 52,  botY: nil, botDiameter: 44, agentMode: .column),
        .note:      ViewLayout(height: 160, botX: 60,  botY: nil, botDiameter: 50, agentMode: .column),
        .settings:  ViewLayout(height: 160, botX: 54,  botY: nil, botDiameter: 46, agentMode: .none),
        .live:      ViewLayout(height: 280, botX: 78,  botY: 96,  botDiameter: 52, agentMode: .none),
        .inbox:     ViewLayout(height: 160, botX: 58,  botY: nil, botDiameter: 48, agentMode: .none),
        // Greeting: bot drawn by GreetingCanvasView; no BotPlacement needed
        .greeting:  ViewLayout(height: 150, botX: 320, botY: 90,  botDiameter: 0,  agentMode: .none),
    ]

    // Project colors — keyed by lowercase display name or slug
    static let projectColors: [String: String] = [
        "korus":             "#FF5A4E",
        "sbe hub":           "#2EC4A0",
        "morning ai brief":  "#F29B38",
        "publication ig":    "#7C5CFF",
        "ig post":           "#7C5CFF",
        "louisraille.fr":    "#38BDF8",
        "louisraille":       "#38BDF8",
        "notch buddy":       "#EC4899",
        "notch-buddy":       "#EC4899",
        "notchbuddy":        "#EC4899",
    ]

    static let fallbackColors = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"]

    // Available integration pills (matches AgentTask.integrationAgents)
    struct IntegrationMeta {
        let id: String
        let name: String
        let color: String
    }
    static let allIntegrations: [IntegrationMeta] = [
        .init(id: "integration_resend",  name: "Resend",  color: "#22C55E"),
        .init(id: "integration_n8n",     name: "n8n",     color: "#F29B38"),
        .init(id: "integration_vercel",  name: "Vercel",  color: "#7C5CFF"),
        .init(id: "integration_github",  name: "GitHub",  color: "#F4505E"),
        .init(id: "integration_notion",  name: "Notion",  color: "#8C8C8C"),
        .init(id: "integration_calcom",  name: "Cal.com", color: "#C9956A"),
        .init(id: "integration_stripe",  name: "Stripe",  color: "#0570DE"),
        .init(id: "integration_linear",  name: "Linear",  color: "#5E6AD2"),
    ]

    /// Returns the fixed project color for a display name, or a stable fallback.
    static func colorForProject(_ name: String) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = projectColors[key] { return c }
        // partial match (e.g. "korus-api" → "korus")
        for (k, c) in projectColors where key.hasPrefix(k) || key.contains(k) { return c }
        return fallbackColors[abs(name.hashValue) % fallbackColors.count]
    }

    // State card wash colors (radial gradient from bottom)
    static let washColors: [IslandView: String] = [
        .approval:  "rgba(245,165,36,0.42)",
        .question:  "rgba(34,211,238,0.38)",
        .error:     "rgba(244,80,94,0.55)",
        .finished:  "rgba(52,211,153,0.5)",
        .confused:  "rgba(244,114,182,0.55)",
        .searching: "rgba(99,102,241,0.5)",
        .result:    "rgba(52,211,153,0.22)",
        .prompt:    "rgba(99,102,241,0.22)",
    ]
}

// MARK: - Frame-rate caps

/// `TimelineView(.animation)` alone renders at the display's maximum rate — 120 fps on
/// ProMotion MacBooks — which kept the open island above 50 % CPU. These caps are
/// visually indistinguishable at the island's size.
enum FrameRate {
    /// Main Mochi, greeting, upload sequence.
    static let main: TimeInterval = 1.0 / 60
    /// Mini Mochis in the integration pills.
    static let mini: TimeInterval = 1.0 / 30
    /// Decorative loops (text shimmer).
    static let decor: TimeInterval = 1.0 / 30
    /// Main Mochi when nobody is interacting (breathing, blinking, compact island).
    static let calm: TimeInterval = 1.0 / 30

    /// Every frame makes SwiftUI rebuild the whole island's display list, so Mochi only
    /// gets 60 fps while the pointer is over the open island (tracking, pokes, emotes).
    @MainActor
    static func mochi(for state: AppState) -> TimeInterval {
        state.mode == .expanded && state.pointerInIsland ? main : calm
    }
}

/// Animation schedule whose ticks land on a shared clock: multiples of `interval`
/// since a fixed epoch. `.animation(minimumInterval:)` counts from when each view
/// appeared, so Mochi, every mini-Mochi and the shimmer ticked out of phase and each
/// forced its own rebuild of the whole island. Aligned ticks coincide, so SwiftUI
/// renders them together — 30 fps really means 30 island updates per second.
struct AlignedAnimationSchedule: TimelineSchedule {
    let interval: TimeInterval
    var paused: Bool = false

    func entries(from date: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var first: Date? = date  // draw now, then join the shared clock
        guard !paused else {
            return AnyIterator { defer { first = nil }; return first }
        }
        // SwiftUI asks for low frequency when frequent updates aren't needed: 1 fps then.
        let step = mode == .lowFrequency ? max(interval, 1) : interval
        var tick = (date.timeIntervalSinceReferenceDate / step).rounded(.down) + 1
        return AnyIterator {
            if let now = first { first = nil; return now }
            defer { tick += 1 }
            return Date(timeIntervalSinceReferenceDate: tick * step)
        }
    }
}
