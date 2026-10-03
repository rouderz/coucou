import Foundation
import SwiftUI
import Combine

// Integration pills — always-present, never purged
extension AgentTask {
    /// All available integration pills. Claude is always active; others are opt-in.
    static let integrationAgents: [AgentTask] = [
        AgentTask(id: "integration_claude",  name: "Claude Code",   color: "#F5F6F8", state: .idle, steps: [], source: .claudeCode, isIntegration: true),
        AgentTask(id: "integration_resend",  name: "Resend",    color: "#22C55E", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_n8n",     name: "n8n",       color: "#F29B38", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_vercel",  name: "Vercel",    color: "#7C5CFF", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_github",  name: "GitHub",    color: "#F4505E", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_notion",  name: "Notion",    color: "#8C8C8C", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_calcom",  name: "Cal.com",   color: "#C9956A", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_stripe",  name: "Stripe",    color: "#0570DE", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_linear",  name: "Linear",    color: "#5E6AD2", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_whaticket", name: "WhaTicket", color: "#25D366", state: .idle, steps: [], source: .n8n, isIntegration: true),
        AgentTask(id: "integration_gmail", name: "Gmail", color: "#EA4335", state: .idle, steps: [], source: .n8n, isIntegration: true),
    ]

    /// IDs that can be toggled (VS Code is always on and excluded from this list)
    static let toggleableIntegrationIds: [String] = [
        "integration_resend", "integration_n8n", "integration_vercel", "integration_github",
        "integration_notion", "integration_calcom", "integration_stripe", "integration_linear",
        "integration_whaticket", "integration_gmail",
    ]

}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Island state
    @Published var mode: IslandMode = .hidden {
        didSet {
            guard mode != oldValue else { return }
            PollGate.shared.setIslandHidden(mode == .hidden)
            updatePillRotation()
            // Opening the island refreshes integrations whose data went stale while it was away.
            if mode == .expanded { PollGate.shared.catchUp() }
        }
    }
    @Published var view: IslandView = .overview

    // Tasks
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil

    // Bot state override
    @Published var stateOverride: BotState? = nil

    // Real notch dimensions (set by IslandWindowController on launch)
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight

    // Last app active before NotchBuddy (for window context capture)
    var lastExternalApp: NSRunningApplication? = nil

    // Bot drag-attach state (hides original bot while ghost follows cursor)
    @Published var isDraggingBot: Bool = false

    // Mouse tracking
    var mousePosition: CGPoint = .zero
    // Editor used to open Claude Code projects (Editor.id); nil = first installed
    @Published var preferredEditor: String? = nil {
        didSet { UserDefaults.standard.set(preferredEditor, forKey: "preferredEditor") }
    }

    // Mochi's chat may edit the attached project (each change approved in the island).
    // Per conversation: reset when a new chat starts.
    @Published var chatAllowEdits: Bool = false
    /// A skill picked with "/" in the chat; its SKILL.md goes with the next question.
    @Published var chatSkill: SkillRef? = nil

    // WhaTicket, as of the browser extension's last check-in (pending queue, my tickets)
    @Published var whaticketUser: String? = nil
    @Published var whaticketQueues: [WhaTicketQueue] = []
    @Published var whaticketPending: [WhaTicketTicket] = []
    @Published var whaticketPendingCount = 0
    @Published var whaticketMine: [WhaTicketTicket] = []
    @Published var whaticketMineCount = 0
    /// Accept clicked (or picked by auto-accept), waiting for the extension.
    @Published var whaticketAccepting: Set<String> = []
    @Published var whaticketSeenAt: Date? = nil
    @Published var whaticketError: String? = nil
    @Published var whaticketLoaded = false

    // Gmail (the Google integration)
    @Published var gmailMails: [GmailMessage] = []
    @Published var gmailTotal = 0
    @Published var gmailError: String? = nil
    @Published var gmailLoaded = false

    // Claude plan usage (5-hour / weekly limits, context), from Claude Code's status line data
    @Published var planUsage: PlanUsage? = nil

    // Live view of the current Claude Code turn (fed by HookServer)
    @Published var liveActivities: [ToolActivity] = []
    @Published var liveEdit: EditPreview? = nil
    @Published var liveProject: String? = nil

    // How the GitHub integration is connected (set by GithubPoller)
    @Published var githubConnection: GitHubConnection = .checking
    var githubCLILogin: String? {
        if case .cli(let login) = githubConnection { return login }
        return nil
    }
    // Pointer over the island — published on enter/leave only; drives Mochi's frame rate
    @Published var pointerInIsland: Bool = false
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    // Upload progress (0-1) — set to 1.0 only at completion; animation is time-based
    @Published var uploadProgress: Double = 0

    // Upload animation timing (non-published — TimelineViews read these directly)
    var uploadStartTime: Date?
    var uploadDuration: Double = 2.4

    // File drag-over state (mailbox morph glow + mouth spring)
    @Published var fileDragOver: Bool = false

    // Sound enabled — persisted
    @Published var soundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Chat engine: the user's Claude Code sign-in (subscription) or an Anthropic API key — persisted
    #if APPSTORE
    static let defaultChatEngine: ChatEngine = .apiKey
    #else
    static let defaultChatEngine: ChatEngine = .claudeCode
    #endif
    @Published var chatEngine: ChatEngine = AppState.defaultChatEngine {
        didSet { UserDefaults.standard.set(chatEngine.rawValue, forKey: "chatEngine") }
    }
    // "Other provider" engine (#43): preset, optional server override, model
    @Published var providerID: String = "openai" {
        didSet { UserDefaults.standard.set(providerID, forKey: "providerID") }
    }
    @Published var providerBaseURL: String = "" {
        didSet { UserDefaults.standard.set(providerBaseURL, forKey: "providerBaseURL") }
    }
    @Published var providerModel: String = "" {
        didSet { UserDefaults.standard.set(providerModel, forKey: "providerModel") }
    }

    // Claude model used by the chat and the search — persisted
    static let defaultClaudeModel = "claude-opus-5-5"
    @Published var claudeModel: String = AppState.defaultClaudeModel {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }
    /// Longest answer the API-key engine may write (tokens). Higher = longer answers, slower and pricier.
    @Published var apiMaxTokens: Int = 4096 {
        didSet { UserDefaults.standard.set(apiMaxTokens, forKey: "apiMaxTokens") }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Context for prompt (window attach / file)
    @Published var promptContext: PromptContext? = nil

    // Dropped file (set during upload flow)
    @Published var droppedFile: DroppedFile? = nil

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Auto-close delay — persisted
    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // Absence interval — persisted
    var absenceInterval: TimeInterval = 3 * 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Greeting threshold — how long hidden before greeting on reappear (default 2 min)
    var greetThresholdSeconds: TimeInterval = 120 {
        didSet { UserDefaults.standard.set(greetThresholdSeconds, forKey: "greetThreshold") }
    }

    // Hotkey to ask Mochi about the file open in the editor (default ⌃⌥M).
    // Global monitors can't swallow keys, so the default is a combo editors don't use.
    @Published var assistantHotkeyEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(assistantHotkeyEnabled, forKey: "assistantHotkeyEnabled")
            NotificationCenter.default.post(name: .assistantHotkeyChanged, object: nil)
        }
    }
    var assistantHotkeyFlags: UInt = NSEvent.ModifierFlags([.control, .option]).rawValue {
        didSet {
            UserDefaults.standard.set(Int(assistantHotkeyFlags), forKey: "assistantHotkeyFlags")
            NotificationCenter.default.post(name: .assistantHotkeyChanged, object: nil)
        }
    }
    var assistantHotkeyCode: UInt16 = 46 {  // 'm'
        didSet {
            UserDefaults.standard.set(Int(assistantHotkeyCode), forKey: "assistantHotkeyCode")
            NotificationCenter.default.post(name: .assistantHotkeyChanged, object: nil)
        }
    }

    // ⌥⏎ Allow / ⌥⌫ Deny while an approval is waiting.
    @Published var approvalShortcutsEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(approvalShortcutsEnabled, forKey: "approvalShortcutsEnabled")
            if !approvalShortcutsEnabled { ApprovalShortcuts.shared.disarm() }
        }
    }

    // Push-to-talk: hold the shortcut (default ⌃⌥V), speak, let go → Mochi answers.
    @Published var voiceEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: "voiceEnabled")
            NotificationCenter.default.post(name: .voiceHotkeyChanged, object: nil)
        }
    }
    var voiceHotkeyFlags: UInt = NSEvent.ModifierFlags([.control, .option]).rawValue {
        didSet {
            UserDefaults.standard.set(Int(voiceHotkeyFlags), forKey: "voiceHotkeyFlags")
            NotificationCenter.default.post(name: .voiceHotkeyChanged, object: nil)
        }
    }
    var voiceHotkeyCode: UInt16 = 9 {  // 'v' (⌃⌥Space is taken by input-source switching)
        didSet {
            UserDefaults.standard.set(Int(voiceHotkeyCode), forKey: "voiceHotkeyCode")
            NotificationCenter.default.post(name: .voiceHotkeyChanged, object: nil)
        }
    }
    /// "auto" (the Mac's language), or a locale such as "es-ES" / "en-US".
    @Published var voiceLanguage: String = "auto" {
        didSet { UserDefaults.standard.set(voiceLanguage, forKey: "voiceLanguage") }
    }
    @Published var voiceSpeakReplies: Bool = true {
        didSet { UserDefaults.standard.set(voiceSpeakReplies, forKey: "voiceSpeakReplies") }
    }
    // "Hey Mochi" (#61): off by default; only on AC power unless changed
    @Published var wakeWordEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(wakeWordEnabled, forKey: "wakeWordEnabled")
            DispatchQueue.main.async { WakeWord.shared.update() }
        }
    }
    @Published var wakeWordOnlyOnPower: Bool = true {
        didSet { UserDefaults.standard.set(wakeWordOnlyOnPower, forKey: "wakeWordOnlyOnPower") }
    }
    @Published var voicePhase: VoicePhase = .idle
    @Published var voiceTranscript: String = ""
    @Published var voiceSpeaking: Bool = false

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    // Vercel project filter — empty = watch all projects
    @Published var vercelProjectFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(vercelProjectFilter)) {
                UserDefaults.standard.set(data, forKey: "vercelProjectFilter")
            }
        }
    }

    // n8n workflow filter — empty = watch all workflows
    @Published var n8nWorkflowFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(n8nWorkflowFilter)) {
                UserDefaults.standard.set(data, forKey: "n8nWorkflowFilter")
            }
        }
    }

    // Active integration pills (Claude Code excluded — always on). The island shows 4 at a time (#111).
    @Published var activeIntegrations: Set<String> = ["integration_resend", "integration_n8n", "integration_vercel", "integration_github"] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(activeIntegrations)) {
                UserDefaults.standard.set(data, forKey: "activeIntegrations")
            }
        }
    }

    /// Seconds between pill rotations when more than 4 are active; 0 = no rotation (#111).
    @Published var pillRotationSeconds: Int = 30 {
        didSet {
            UserDefaults.standard.set(pillRotationSeconds, forKey: "pillRotationSeconds")
            updatePillRotation()
        }
    }
    @Published private(set) var pillRotationOffset: Int = 0
    private var pillRotationTimer: Timer?

    /// Pills that never rotate out of the island (context menu on a pill).
    @Published var pinnedPills: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(pinnedPills), forKey: "pinnedPills")
            updatePillRotation()
        }
    }

    func togglePinned(_ id: String) {
        if pinnedPills.contains(id) { pinnedPills.remove(id) } else { pinnedPills.insert(id) }
    }

    /// The pills the island shows next to the focused one: up to 4, rotating through the rest.
    var visiblePills: [AgentTask] {
        let others = tasks.filter { $0.id != focusId }
        let news = Set(others.filter { $0.pillBadge != nil }.map(\.id))
        let ids = PillRotation.visible(ids: others.map(\.id), pinned: pinnedPills, news: news, offset: pillRotationOffset)
        return others.filter { ids.contains($0.id) }
    }

    /// Active pills that aren't in the island right now (the "+N" strip).
    var overflowPills: [AgentTask] {
        let shown = Set(visiblePills.map(\.id))
        return tasks.filter { $0.id != focusId && !shown.contains($0.id) }
    }

    /// How many active pills don't fit in the island right now.
    var hiddenPillCount: Int { max(0, tasks.filter { $0.id != focusId }.count - PillRotation.slots) }

    /// The rotation timer exists only while the island is showing and there is something to rotate: 0 % CPU otherwise.
    func updatePillRotation() {
        pillRotationTimer?.invalidate()
        pillRotationTimer = nil
        guard mode != .hidden, pillRotationSeconds > 0, hiddenPillCount > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(pillRotationSeconds), repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = AppState.shared
                guard s.hiddenPillCount > 0 else { s.updatePillRotation(); return }
                s.pillRotationOffset += 1
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pillRotationTimer = timer
    }

    // Pending API result
    @Published var searchResult: SearchResult? = nil

    // Vercel deployments (populated by VercelPoller)
    @Published var vercelDeployments: [VercelDeployment] = []

    // Resend emails (populated by ResendPoller)
    @Published var resendEmails: [ResendEmail] = []
    @Published var resendTotal: Int? = nil

    // GitHub stats (populated by GithubPoller)
    @Published var githubStats: GitHubStats? = nil

    // Stripe (populated by StripePoller)
    @Published var stripePayments: [StripePayment] = []
    /// Succeeded payments per day, oldest first, last 7 days (smallest currency unit) (#25).
    @Published var stripeDaily: [Int] = []
    @Published var stripeBalance: Int = 0           // raw balance in cents
    @Published var stripeDisplayBalance: Int = 0    // animated balance target
    @Published var stripeCurrency: String = "eur"
    @Published var stripeLoaded: Bool = false       // true after first successful poll
    @Published var stripeError: String? = nil      // last API error (nil = ok)

    // Cal.com (populated by CalcomPoller)
    @Published var calcomBookings: [CalcomBooking] = []
    @Published var calcomLoaded: Bool = false
    @Published var calcomError: String? = nil

    // Linear (#26): your open assigned issues
    @Published var linearIssues: [LinearIssue] = []
    @Published var linearLoaded: Bool = false
    @Published var linearError: String? = nil

    // Notion (populated by NotionPoller)
    @Published var notionPages: [NotionPage] = []
    // Last poll result for integrations without their own error state (Vercel, Resend, n8n)
    @Published var integrationHealth: [String: IntegrationHealth] = [:]
    @Published var notionLoaded: Bool = false
    @Published var notionError: String? = nil

    // Update check against GitHub releases (#40)
    @Published var updateChecks: Bool = true {
        didSet { UserDefaults.standard.set(updateChecks, forKey: "updateChecks") }
    }

    // Inbox: reviews, mentions and assignments from GitHub and Linear
    @Published var inboxEnabled: Bool = true {
        didSet { UserDefaults.standard.set(inboxEnabled, forKey: "inboxEnabled") }
    }
    @Published var inboxGitHub: Bool = true {
        didSet { UserDefaults.standard.set(inboxGitHub, forKey: "inboxGitHub") }
    }
    @Published var inboxLinear: Bool = true {
        didSet { UserDefaults.standard.set(inboxLinear, forKey: "inboxLinear") }
    }
    /// Mochi says new inbox items out loud (push-to-talk voice and language).
    @Published var inboxSpeak: Bool = false {
        didSet { UserDefaults.standard.set(inboxSpeak, forKey: "inboxSpeak") }
    }
    /// InboxItem.Kind raw values that count (comments and other updates are off by default).
    @Published var inboxKinds: Set<String> = ["review", "mention", "assigned"] {
        didSet { UserDefaults.standard.set(Array(inboxKinds), forKey: "inboxKinds") }
    }

    // Phone alerts for approvals nobody answered (#31)
    @Published var phoneAlertsEnabled: Bool = false {
        didSet { UserDefaults.standard.set(phoneAlertsEnabled, forKey: "phoneAlertsEnabled") }
    }
    @Published var phoneAlertsTopic: String = "" {
        didSet { UserDefaults.standard.set(phoneAlertsTopic, forKey: "phoneAlertsTopic") }
    }
    @Published var phoneAlertsServer: String = "https://ntfy.sh" {
        didSet { UserDefaults.standard.set(phoneAlertsServer, forKey: "phoneAlertsServer") }
    }
    @Published var phoneAlertsOnlyWhenAway: Bool = true {
        didSet { UserDefaults.standard.set(phoneAlertsOnlyWhenAway, forKey: "phoneAlertsOnlyWhenAway") }
    }

    // Do not disturb (#30)
    @Published var dndUntil: Date? = nil {
        didSet { UserDefaults.standard.set(dndUntil, forKey: "dndUntil") }
    }
    @Published var dndDuringMeetings: Bool = false {
        didSet {
            UserDefaults.standard.set(dndDuringMeetings, forKey: "dndDuringMeetings")
            // Deferred: this also runs while AppState.shared is still being created (saved settings),
            // and refresh() reads AppState.shared — calling it now would deadlock the app at launch.
            if dndDuringMeetings != oldValue { DispatchQueue.main.async { DoNotDisturb.shared.refresh() } }
        }
    }
    @Published var dndInMeeting: Bool = false
    var dndMeetingEnd: Date? = nil
    var dndSkippedMeetingEnd: Date? = nil

    // Claude Code sessions running at the same time (#24). The card shows the focused one.
    @Published var claudeSessions: [ClaudeSession] = []
    /// The live view shows the session's timeline instead of the diff (#22).
    @Published var liveShowsTimeline: Bool = false
    @Published var focusedClaudeSession: String? = nil

    // Chat conversation on screen, and its entry in ChatStore once saved
    @Published var chatHistory: [ChatMessage] = []
    @Published var currentChatID: UUID? = nil

    // Pending approval request from Claude Code hook
    @Published var pendingApproval: ApprovalInfo? = nil

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = UserDefaults.standard

        if let v = ud.object(forKey: "soundEnabled") as? Bool   { soundEnabled = v }
        if let v = ud.object(forKey: "soundVolume")  as? Double { soundVolume  = v }
        #if !APPSTORE
        if let v = ud.string(forKey: "chatEngine"), let e = ChatEngine(rawValue: v) { chatEngine = e }
        if let v = ud.string(forKey: "providerID") { providerID = v }
        if let v = ud.string(forKey: "providerBaseURL") { providerBaseURL = v }
        if let v = ud.string(forKey: "providerModel") { providerModel = v }
        #endif
        preferredEditor = ud.string(forKey: "preferredEditor")
        if let v = ud.object(forKey: "apiMaxTokens") as? Int, v >= 256 { apiMaxTokens = v }
        if let v = ud.string(forKey: "claudeModel"),
           !v.trimmingCharacters(in: .whitespaces).isEmpty { claudeModel = v }
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { absenceInterval   = v }
        if let v = ud.object(forKey: "greetThreshold")    as? Double { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { hotkeyCode = UInt16(v) }
        if let v = ud.object(forKey: "assistantHotkeyEnabled") as? Bool { assistantHotkeyEnabled = v }
        if let v = ud.object(forKey: "assistantHotkeyFlags")   as? Int  { assistantHotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "assistantHotkeyCode")    as? Int  { assistantHotkeyCode = UInt16(v) }
        if let v = ud.object(forKey: "approvalShortcutsEnabled") as? Bool { approvalShortcutsEnabled = v }
        if let v = ud.object(forKey: "dndUntil") as? Date, v > .now { dndUntil = v }
        if let v = ud.object(forKey: "phoneAlertsEnabled") as? Bool { phoneAlertsEnabled = v }
        if let v = ud.object(forKey: "inboxEnabled") as? Bool { inboxEnabled = v }
        if let v = ud.object(forKey: "updateChecks") as? Bool { updateChecks = v }
        if let v = ud.object(forKey: "inboxGitHub") as? Bool { inboxGitHub = v }
        if let v = ud.object(forKey: "inboxLinear") as? Bool { inboxLinear = v }
        if let v = ud.object(forKey: "inboxSpeak") as? Bool { inboxSpeak = v }
        if let v = ud.stringArray(forKey: "inboxKinds") { inboxKinds = Set(v) }
        if let v = ud.string(forKey: "phoneAlertsTopic") { phoneAlertsTopic = v }
        if let v = ud.string(forKey: "phoneAlertsServer"), !v.isEmpty { phoneAlertsServer = v }
        if let v = ud.object(forKey: "phoneAlertsOnlyWhenAway") as? Bool { phoneAlertsOnlyWhenAway = v }
        if let v = ud.object(forKey: "dndDuringMeetings") as? Bool { dndDuringMeetings = v }
        if let v = ud.object(forKey: "voiceEnabled")      as? Bool   { voiceEnabled = v }
        if let v = ud.object(forKey: "voiceHotkeyFlags")  as? Int    { voiceHotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "voiceHotkeyCode")   as? Int    { voiceHotkeyCode = UInt16(v) }
        if let v = ud.object(forKey: "voiceLanguage")     as? String { voiceLanguage = v }
        if let v = ud.object(forKey: "voiceSpeakReplies") as? Bool   { voiceSpeakReplies = v }
        if let v = ud.object(forKey: "pillRotationSeconds") as? Int { pillRotationSeconds = v }
        if let v = ud.stringArray(forKey: "pinnedPills") { pinnedPills = Set(v) }
        if let v = ud.object(forKey: "wakeWordEnabled") as? Bool { wakeWordEnabled = v }
        if let v = ud.object(forKey: "wakeWordOnlyOnPower") as? Bool { wakeWordOnlyOnPower = v }
        if let d = ud.data(forKey: "vercelProjectFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { vercelProjectFilter = Set(a) }
        if let d = ud.data(forKey: "n8nWorkflowFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { n8nWorkflowFilter = Set(a) }
        if let d = ud.data(forKey: "activeIntegrations"),
           let a = try? JSONDecoder().decode([String].self, from: d) { activeIntegrations = Set(a) }

        // Sync SoundEngine volume on launch
        SoundEngine.shared.volume = Float(soundVolume)

        // Always load integration pills
        loadIntegrationTasks()
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    var effectiveState: BotState {
        stateOverride ?? focusTask?.state ?? .idle
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = tasks.first?.id }
        syncMode()
        syncView()
    }

    func updateTask(id: String, state: BotState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
    }

    func setFocus(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        focusId = id
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
    }

    func syncMode() {
        // If no tasks and not expanded/peek, go hidden
        if tasks.isEmpty && mode == .compact {
            mode = .hidden
        } else if !tasks.isEmpty && mode == .hidden && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// Load integration pills respecting activeIntegrations. Claude Code always loads. Safe to call multiple times.
    func loadIntegrationTasks() {
        for task in AgentTask.integrationAgents {
            let shouldLoad = task.id == "integration_claude" || activeIntegrations.contains(task.id)
            let loaded = tasks.contains(where: { $0.id == task.id })
            if shouldLoad && !loaded { tasks.append(task) }
            if !shouldLoad && loaded { tasks.removeAll { $0.id == task.id } }
        }
        if focusId == nil { focusId = "integration_claude" }
        syncMode()
        updatePillRotation()
    }

    /// Toggle an integration pill on/off. Claude Code cannot be toggled.
    func toggleIntegration(_ id: String) {
        guard id != "integration_claude" else { return }
        if activeIntegrations.contains(id) {
            activeIntegrations.remove(id)
            tasks.removeAll { $0.id == id }
            if focusId == id { focusId = "integration_claude" }
        } else {
            activeIntegrations.insert(id)
            if let task = AgentTask.integrationAgents.first(where: { $0.id == id }),
               !tasks.contains(where: { $0.id == id }) {
                tasks.append(task)
            }
        }
        syncMode()
        updatePillRotation()
    }

}

// MARK: - Supporting types

enum PromptContext {
    case window(appName: String, title: String, url: String?)
    case file(name: String, fileURL: URL?)
    case code(CodeContext)  // the file open in the user's editor (assistant mode)
}

struct DroppedFile {
    var url: URL
    var name: String
}

struct SearchResult {
    var title: String
    var items: [ResultItem]
    var note: String?
}

struct ResultItem {
    var label: String
    var detail: String
    var url: String?
}

// MARK: - Vercel

struct VercelDeployment: Identifiable {
    let id: String
    let projectName: String
    let url: String
    let state: String        // "READY", "ERROR", "CANCELED"
    let createdAt: Date
    let commitMessage: String?
    let branch: String?
    /// Seconds from build start to ready/error (#25), when Vercel reports both.
    var buildSeconds: Double? = nil

    var isSuccess: Bool { state == "READY" }
    var buildTime: String? { buildSeconds.map { TimelineStore.format($0) } }
    var statusLabel: String { isSuccess ? "Ready" : (state == "CANCELED" ? "Canceled" : "Error") }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return L("just now") }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Resend

struct ResendEmail: Identifiable {
    let id: String
    let to: [String]
    let subject: String
    let createdAt: Date
    let lastEvent: String   // "delivered", "bounced", "complained", "opened", etc.

    var recipientShort: String {
        guard let first = to.first else { return "?" }
        return first.components(separatedBy: "@").first ?? first
    }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return L("just now") }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
    var isDelivered: Bool { lastEvent == "delivered" }
}

// MARK: - GitHub

struct GitHubStats {
    let totalRepos: Int
    let totalStars: Int
}

// MARK: - Stripe

struct StripePayment: Identifiable, Equatable {
    let id: String
    let amount: Int         // in cents/smallest unit
    let currency: String
    let description: String?
    let createdAt: Date
    let status: String      // "succeeded", "pending", "failed"

    var amountFormatted: String { String(format: "%.2f", Double(amount) / 100.0) }
    var isSuccess: Bool { status == "succeeded" }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return L("just now") }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Cal.com

struct CalcomBooking: Identifiable, Equatable {
    let id: Int
    let title: String
    let startTime: Date
    let endTime: Date
    let status: String
    let attendeeName: String?
    let attendeeEmail: String?
    let attendeeNotes: String?

    var isActive: Bool { status == "ACCEPTED" || status == "PENDING" }
    var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: startTime)
    }
    var dayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: startTime)
        return "\(c.year!)-\(String(format: "%02d", c.month!))-\(String(format: "%02d", c.day!))"
    }
}

// MARK: - Notion

struct NotionPage: Identifiable {
    let id: String
    let title: String
    let emoji: String?
    let lastEditedAt: Date
    let url: String

    var timeAgo: String {
        let diff = Date().timeIntervalSince(lastEditedAt)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Claude Code sessions

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    var project: String
    var cwd: String
    /// "claude" or "codex" (#44).
    var agent: String = "claude"
    var state: BotState = .idle
    var steps: [String] = []
    var updatedAt: Date = .now
    /// Something happened here while another session was on the card.
    var unseen: Bool = false
    /// Git branch and the Linear issue it names (#27).
    var branch: String? = nil
    var linear: LinearIssue? = nil
}

// MARK: - Chat

enum ChatRole { case user, assistant }

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    var content: String
}

enum GitHubConnection: Equatable {
    case checking
    case cli(login: String?)   // signed-in GitHub CLI
    case token                 // Personal Access Token from Settings
    case ghSignedOut           // gh installed but not signed in, and no token
    case notConfigured         // no gh, no token
    case failed(String)

    var isConnected: Bool {
        switch self { case .cli, .token: return true; default: return false }
    }
}

enum ChatEngine: String {
    case claudeCode  // the user's own Claude Code CLI, signed in with their subscription
    case apiKey      // Anthropic API with the key saved in the Keychain
    case provider    // another provider: OpenAI, Gemini, OpenRouter, Ollama… (#42)
}

// MARK: - Integration refresh

/// Re-polls integrations on demand (card refresh button, keys saved in Settings).
enum IntegrationRefresher {
    @MainActor
    static func refresh(_ id: String, fromUser: Bool = true) {
        // A click on refresh (or a saved key) always polls and clears any error backoff.
        if fromUser { PollGate.shared.manual(id) }
        switch id {
        case "integration_github":
            if fromUser { AppState.shared.githubConnection = .checking }
        case "integration_notion":
            AppState.shared.notionError = nil
        default: break
        }
        Integrations.source(id)?.pollNow()
    }

    @MainActor
    static func refreshAll() {
        for source in Integrations.all { refresh(source.integrationID) }
    }
}

// MARK: - Integration status light

enum IntegrationHealth: Equatable, Sendable {
    case ok
    case empty(String)   // connected, but nothing to show yet
    case error(String)
}

/// The same green / amber / red / grey light on every integration card.
struct IntegrationStatus {
    let colorHex: String
    let help: String

    static let green = "#22C55E", amber = "#F5A524", red = "#F4505E", grey = "#6B7079"

    /// Reports a poll result from any thread.
    static func report(_ id: String, _ health: IntegrationHealth) {
        DispatchQueue.main.async { AppState.shared.integrationHealth[id] = health }
    }

    @MainActor
    static func of(_ id: String, _ s: AppState = .shared) -> IntegrationStatus {
        func key(_ k: String) -> Bool { Secrets.store.get(k).map { !$0.isEmpty } ?? false }
        let notSet = IntegrationStatus(colorHex: red, help: L("Not configured · add it in Settings"))
        let checking = IntegrationStatus(colorHex: grey, help: L("Checking connection…"))

        switch id {
        case "integration_github":
            switch s.githubConnection {
            case .cli(let login): return .init(colorHex: green, help: login.map { L("Connected via GitHub CLI · @\($0)") } ?? L("Connected via GitHub CLI"))
            case .token:          return .init(colorHex: green, help: L("Connected with token"))
            case .checking:       return checking
            case .ghSignedOut:    return .init(colorHex: red, help: L("GitHub CLI signed out · run gh auth login"))
            case .notConfigured:  return notSet
            case .failed(let w):  return .init(colorHex: red, help: w)
            }
        case "integration_linear":
            guard key(LinearAPI.keychainKey) else { return notSet }
            if let e = s.linearError { return .init(colorHex: red, help: e) }
            guard s.linearLoaded else { return checking }
            return .init(colorHex: s.linearIssues.isEmpty ? amber : green,
                         help: s.linearIssues.isEmpty ? L("Connected · nothing assigned to you")
                                                      : L("Connected · \(s.linearIssues.count) open issues"))
        case "integration_gmail":
            guard GoogleAPI.isConnected else { return notSet }
            if let e = s.gmailError { return .init(colorHex: red, help: e) }
            guard s.gmailLoaded else { return checking }
            let email = UserDefaults.standard.string(forKey: "googleEmail") ?? ""
            return .init(colorHex: green, help: email.isEmpty ? "Connected" : L("Signed in as \(email)"))
        case "integration_whaticket":
            guard BrowserExtension.isSetUp else { return notSet }
            if let e = s.whaticketError { return .init(colorHex: red, help: e) }
            guard let seen = s.whaticketSeenAt, Date.now.timeIntervalSince(seen) < WhaTicketBridge.staleAfter else {
                return .init(colorHex: amber, help: L("Open whaticket.com in Chrome or Edge"))
            }
            return .init(colorHex: green, help: s.whaticketUser.map { L("Signed in as \($0)") } ?? "Connected")
        case "integration_notion":
            guard key("notion-api-key") else { return notSet }
            if let e = s.notionError { return .init(colorHex: red, help: e) }
            guard s.notionLoaded else { return checking }
            return s.notionPages.isEmpty
                ? .init(colorHex: amber, help: L("Connected, but no pages are shared with the integration"))
                : .init(colorHex: green, help: L("Connected · \(s.notionPages.count) recent pages"))
        case "integration_stripe":
            guard key("stripe-api-key") else { return notSet }
            if let e = s.stripeError { return .init(colorHex: red, help: e) }
            guard s.stripeLoaded else { return checking }
            return s.stripePayments.isEmpty
                ? .init(colorHex: amber, help: L("Connected · no payments yet"))
                : .init(colorHex: green, help: "Connected")
        case "integration_calcom":
            guard key("calcom-api-key") else { return notSet }
            if let e = s.calcomError { return .init(colorHex: red, help: e) }
            guard s.calcomLoaded else { return checking }
            return s.calcomBookings.isEmpty
                ? .init(colorHex: amber, help: L("Connected · no upcoming bookings"))
                : .init(colorHex: green, help: "Connected")
        case "integration_vercel", "integration_resend", "integration_n8n":
            let k = ["integration_vercel": "vercel-token", "integration_resend": "resend-api-key",
                     "integration_n8n": "n8n-api-key"][id]!
            guard key(k) else { return notSet }
            switch s.integrationHealth[id] {
            case .ok:             return .init(colorHex: green, help: "Connected")
            case .empty(let w):   return .init(colorHex: amber, help: w)
            case .error(let w):   return .init(colorHex: red, help: w)
            case nil:             return checking
            }
        default:
            return .init(colorHex: grey, help: "")
        }
    }

    /// Error text for an HTTP failure, shared by the pollers.
    static func httpError(_ service: String, code: Int, error: Error? = nil) -> String {
        switch code {
        case 401, 403: return L("Invalid key or no access (\(code))")
        case 0:        return error.map { L("Can't reach \(service) · \($0.localizedDescription)") } ?? L("Can't reach \(service)")
        default:       return "\(service) error \(code)"
        }
    }
}

// MARK: - Claude plan usage

/// What Claude Code reports to its status line: plan limits (Pro/Max) and the context window.
struct PlanUsage: Equatable {
    struct Window: Equatable {
        let percent: Double      // 0–100
        let resetsAt: Date
    }
    var fiveHour: Window? = nil
    var sevenDay: Window? = nil
    var contextPercent: Double? = nil
    /// When the context % last arrived (it belongs to the session that's running right now).
    var contextUpdatedAt: Date? = nil
    var model: String? = nil
    /// "Pro", "Max"… from the Claude Code login.
    var plan: String? = nil
    var updatedAt: Date = .now
}
