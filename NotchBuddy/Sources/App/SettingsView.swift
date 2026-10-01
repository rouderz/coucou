import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @State private var apiKey: String = KeychainStore.shared.get("anthropic-api-key") ?? ""

    // Claude model — presets plus a free field for any other model ID
    private static let modelPresets: [(id: String, label: String)] = [
        ("claude-opus-5-5",   "Claude Opus 5.5"),
        ("claude-fable-5-1",  "Claude Fable 5.1"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-4-5",  "Claude Haiku 4.5"),
    ]
    private static let customModelTag = "__custom__"
    @State private var modelChoice: String = {
        let m = AppState.shared.claudeModel
        return SettingsView.modelPresets.contains { $0.id == m } ? m : SettingsView.customModelTag
    }()
    @State private var customModel: String = {
        let m = AppState.shared.claudeModel
        return SettingsView.modelPresets.contains { $0.id == m } ? "" : m
    }()
    @State private var ghStatus: GitHubCLI.Status? = nil
    @State private var checkingGh = false
    @State private var claudeCodePath: String? = ClaudeCodeChat.install?.path
    @State private var checkingClaudeCode = false
    @State private var launchAtStartup: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var statusMessage: String = ""
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()
    #if APPSTORE
    @State private var claudeAccessGranted: Bool = (UserDefaults.standard.data(forKey: "claudeDirectoryBookmark") != nil)
    #endif

    // Integration keys
    @State private var resendKey: String    = KeychainStore.shared.get("resend-api-key")  ?? ""
    @State private var resendFrom: String   = KeychainStore.shared.get("resend-from")     ?? ""
    @State private var n8nUrl: String       = KeychainStore.shared.get("n8n-url")         ?? ""
    @State private var n8nKey: String       = KeychainStore.shared.get("n8n-api-key")     ?? ""
    @State private var vercelToken: String  = KeychainStore.shared.get("vercel-token")    ?? ""
    @State private var githubToken: String  = KeychainStore.shared.get("github-token")    ?? ""
    @State private var stripeKey: String    = KeychainStore.shared.get("stripe-api-key")  ?? ""
    @State private var calcomKey: String    = KeychainStore.shared.get("calcom-api-key")  ?? ""
    @State private var notionKey: String    = KeychainStore.shared.get("notion-api-key")  ?? ""

    // Hotkey
    @State private var hotkeyFlags: UInt    = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16   = AppState.shared.hotkeyCode
    @State private var axTrusted = AccessibilityAccess.isTrusted
    @State private var assistantFlags: UInt   = AppState.shared.assistantHotkeyFlags
    @State private var assistantCode: UInt16  = AppState.shared.assistantHotkeyCode
    @State private var voiceFlags: UInt       = AppState.shared.voiceHotkeyFlags
    @State private var voiceCode: UInt16      = AppState.shared.voiceHotkeyCode
    @State private var voiceAllowed: Bool     = VoiceInput.permissionsGranted

    // Vercel project filter
    @State private var vercelProjects: [String] = []
    @State private var loadingVercel: Bool = false

    // n8n workflow filter
    @State private var n8nWorkflows: [String] = []
    @State private var loadingN8n: Bool = false

    // Bindings in minutes for the absence field
    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                // MARK: API
                GroupBox("Chat") {
                    VStack(alignment: .leading, spacing: 8) {
                        #if !APPSTORE
                        Picker("Engine", selection: $state.chatEngine) {
                            Text("Claude Code (subscription)").tag(ChatEngine.claudeCode)
                            Text("Anthropic API key").tag(ChatEngine.apiKey)
                        }
                        .pickerStyle(.segmented)
                        #endif

                        if state.chatEngine == .claudeCode {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(claudeCodePath == nil ? Color.orange : Color.green)
                                    .frame(width: 7, height: 7)
                                Text(claudeCodePath.map { "Claude Code found: \($0)" }
                                     ?? "Claude Code not found. Install it and sign in, then check again.")
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(checkingClaudeCode ? "Checking…" : "Check again") {
                                    checkingClaudeCode = true
                                    Task {
                                        claudeCodePath = await ClaudeCodeChat.locate(force: true)?.path
                                        checkingClaudeCode = false
                                    }
                                }
                                .disabled(checkingClaudeCode)
                            }
                            Text("Uses your Claude Code sign-in and plan limits — no API key needed. The chat can only search the web and read files you drop on the island.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            SecureField("API key (sk-ant-…)", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                KeychainStore.shared.set("anthropic-api-key", value: apiKey)
                                statusMessage = "✓ Key saved."
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Divider().padding(.vertical, 2)

                        Picker("Model", selection: $modelChoice) {
                            ForEach(Self.modelPresets, id: \.id) { preset in
                                Text(preset.label).tag(preset.id)
                            }
                            Text("Custom…").tag(Self.customModelTag)
                        }
                        .onChange(of: modelChoice) { _, choice in
                            if choice != Self.customModelTag {
                                state.claudeModel = choice
                            } else {
                                applyCustomModel(customModel)
                            }
                        }

                        if modelChoice == Self.customModelTag {
                            TextField("Model ID (e.g. claude-opus-5-5)", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: customModel) { _, value in applyCustomModel(value) }
                        }

                        Text("Used by the chat. Fable needs access on your plan or API account.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        if state.chatEngine == .apiKey {
                            Picker("Longest answer", selection: $state.apiMaxTokens) {
                                Text("Short (1,024 tokens)").tag(1024)
                                Text("Medium (2,048)").tag(2048)
                                Text("Long (4,096)").tag(4096)
                                Text("Very long (8,192)").tag(8192)
                                Text("Maximum (16,000)").tag(16000)
                            }
                            Text("Caps how much each API answer can write. Longer answers cost more tokens.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(6)
                }

                // MARK: Hooks
                GroupBox("Claude Code Hooks") {
                    VStack(alignment: .leading, spacing: 10) {
                        if hookNeedsUpdate {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Hooks need an update (approvals timeout / plan usage bars)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                            #if APPSTORE
                            Button("Update hooks") { installHooksAppStore() }
                            #else
                            Button("Update hooks") { installHooks() }
                            #endif
                        }
                        #if APPSTORE
                        if claudeAccessGranted {
                            Text("~/.claude/coucou/nb-hook")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            HStack(spacing: 10) {
                                Button("Install hooks") { installHooksAppStore() }
                                    .buttonStyle(.borderedProminent)
                                Button("Uninstall") { uninstallHooksAppStore() }
                                    .buttonStyle(.bordered)
                            }
                        } else {
                            Text("Choose your ~/.claude folder so Coucou can add its hooks.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Button("Choose .claude folder…") { chooseClaudeFolder() }
                                .buttonStyle(.borderedProminent)
                        }
                        #else
                        Text("nb-hook : \(HookServer.hookScriptPath)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button("Install hooks") { installHooks() }
                                .buttonStyle(.borderedProminent)
                            Button("Uninstall") { uninstallHooks() }
                                .buttonStyle(.bordered)
                        }
                        #endif

                        if showDiff {
                            ScrollView {
                                Text(pendingHookJSON)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 140)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)

                            HStack {
                                #if APPSTORE
                                Button("Confirm & write") { confirmInstallAppStore() }
                                    .buttonStyle(.borderedProminent)
                                #else
                                Button("Confirm & write") { confirmInstall() }
                                    .buttonStyle(.borderedProminent)
                                #endif
                                Button("Cancel") { showDiff = false; pendingHookJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }

                        Divider().padding(.vertical, 2)
                        let editors = Editor.installed
                        if editors.isEmpty {
                            Text("No supported editor found. Projects open in Finder.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Open projects in", selection: Binding(
                                get: { Editor.preferred(state.preferredEditor)?.id ?? editors[0].id },
                                set: { state.preferredEditor = $0 }
                            )) {
                                ForEach(editors) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                    .padding(6)
                }

                // MARK: Integrations
                GroupBox("Integrations") {
                    VStack(alignment: .leading, spacing: 14) {

                        // Resend
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#22C55E")).frame(width: 8, height: 8)
                                Text("Resend").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("API key  (re_…)", text: $resendKey)
                                .textFieldStyle(.roundedBorder)
                            TextField("From address  (you@yourdomain.com)", text: $resendFrom)
                                .textFieldStyle(.roundedBorder)
                        }

                        // n8n
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#F29B38")).frame(width: 8, height: 8)
                                Text("n8n").font(.system(size: 12, weight: .semibold))
                            }
                            TextField("Instance URL  (https://…)", text: $n8nUrl)
                                .textFieldStyle(.roundedBorder)
                            SecureField("API key", text: $n8nKey)
                                .textFieldStyle(.roundedBorder)
                            IntegrationFilterRow(
                                label: "Workflows",
                                items: n8nWorkflows,
                                filter: $state.n8nWorkflowFilter,
                                loading: loadingN8n,
                                onLoad: loadN8nWorkflows
                            )
                        }

                        // Vercel
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#7C5CFF")).frame(width: 8, height: 8)
                                Text("Vercel").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("Token", text: $vercelToken)
                                .textFieldStyle(.roundedBorder)
                            IntegrationFilterRow(
                                label: "Projects",
                                items: vercelProjects,
                                filter: $state.vercelProjectFilter,
                                loading: loadingVercel,
                                onLoad: loadVercelProjects
                            )
                        }

                        // GitHub
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#F4505E")).frame(width: 8, height: 8)
                                Text("GitHub").font(.system(size: 12, weight: .semibold))
                            }
                            #if !APPSTORE
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(state.githubConnection.isConnected ? Color.green
                                          : checkingGh ? Color.gray : Color.orange)
                                    .frame(width: 7, height: 7)
                                Text(ghStatusText)
                                    .font(.system(size: 11))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button(checkingGh ? "Testing…" : "Test connection") { checkGitHubCLI(force: true) }
                                    .disabled(checkingGh)
                            }
                            #endif
                            SecureField(ghStatus == .signedIn
                                        ? "Personal Access Token (not needed while gh is signed in)"
                                        : "Personal Access Token",
                                        text: $githubToken)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Stripe
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#0570DE")).frame(width: 8, height: 8)
                                Text("Stripe").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("Secret key  (sk_live_… or sk_test_…)", text: $stripeKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Cal.com
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#C9956A")).frame(width: 8, height: 8)
                                Text("Cal.com").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("API key  (cal_live_…)", text: $calcomKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Notion
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#E8E8E8")).frame(width: 8, height: 8)
                                Text("Notion").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("Integration token  (secret_…)", text: $notionKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button("Save integrations") { saveIntegrations() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(6)
                }

                // MARK: Son
                GroupBox("Sound") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable sounds", isOn: $state.soundEnabled)
                        HStack(spacing: 8) {
                            Text("Volume")
                                .frame(width: 56, alignment: .leading)
                            Slider(value: $state.soundVolume, in: 0...0.2)
                                .disabled(!state.soundEnabled)
                            Text("\(Int(state.soundVolume / 0.2 * 100)) %")
                                .frame(width: 36, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                    .padding(6)
                }

                // MARK: Timings
                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Close after")
                            TextField("60", value: $state.autoCloseInterval, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("s inactive")
                        }
                        HStack(spacing: 8) {
                            Text("Hide after")
                            TextField("3", value: absenceMinutes, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 48)
                            Text("min without movement")
                        }
                    }
                    .padding(6)
                }

                // MARK: Active pills
                GroupBox("Active pills") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Claude Code")
                                .font(.system(size: 12, weight: .semibold))
                            Circle().fill(Color(hex: "#F5F6F8")).frame(width: 8, height: 8)
                            Spacer()
                            Text("Always active")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        Text("\(state.activeIntegrations.count)/4 slots used")
                            .font(.system(size: 11))
                            .foregroundColor(state.activeIntegrations.count >= 4 ? .orange : .secondary)

                        ForEach(AgentTask.toggleableIntegrationIds, id: \.self) { id in
                            let task = AgentTask.integrationAgents.first { $0.id == id }!
                            let isOn = state.activeIntegrations.contains(id)
                            let atMax = state.activeIntegrations.count >= 4 && !isOn
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: task.color))
                                    .frame(width: 10, height: 10)
                                Text(task.name)
                                    .font(.system(size: 12))
                                    .foregroundColor(atMax ? .secondary : .primary)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { isOn },
                                    set: { _ in state.toggleIntegration(id) }
                                ))
                                .labelsHidden()
                                .disabled(atMax)
                            }
                        }
                    }
                    .padding(6)
                }

                // MARK: Hotkey
                GroupBox("Hotkey") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show island with shortcut", isOn: $state.hotkeyEnabled)
                        if state.hotkeyEnabled {
                            HStack(spacing: 8) {
                                Text("Shortcut")
                                    .frame(width: 70, alignment: .leading)
                                ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                                    .onChange(of: hotkeyFlags) { _, v in state.hotkeyFlags = v }
                                    .onChange(of: hotkeyCode)  { _, v in state.hotkeyCode  = v }
                                Text("presses this → island opens")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider().padding(.vertical, 2)
                        Toggle("Ask Mochi about the file you're editing", isOn: $state.assistantHotkeyEnabled)
                        if state.assistantHotkeyEnabled {
                            HStack(spacing: 8) {
                                Text("Shortcut")
                                    .frame(width: 70, alignment: .leading)
                                ShortcutRecorderButton(flags: $assistantFlags, code: $assistantCode)
                                    .onChange(of: assistantFlags) { _, v in state.assistantHotkeyFlags = v }
                                    .onChange(of: assistantCode)  { _, v in state.assistantHotkeyCode  = v }
                                Text("attaches the open file + selection")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Text("Mochi can read and search that project but never edits it.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Circle().fill(axTrusted ? Color.green : Color.orange).frame(width: 7, height: 7)
                                Text(axTrusted ? "Accessibility access granted"
                                               : "Accessibility access needed to read the open file")
                                    .font(.system(size: 11))
                                Spacer()
                                if !axTrusted {
                                    Button("Grant access…") { AccessibilityAccess.request() }
                                }
                                Button("Check") { axTrusted = AccessibilityAccess.isTrusted }
                            }
                        }

                        Divider().padding(.vertical, 2)
                        Toggle("Approve from the keyboard: ⌥⏎ Allow · ⌥⌫ Deny", isOn: $state.approvalShortcutsEnabled)
                        Text("Only active while Claude Code is waiting for you. High-risk requests need a click on Allow.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider().padding(.vertical, 2)
                        Toggle("Push-to-talk: hold to talk to Mochi", isOn: $state.voiceEnabled)
                        if state.voiceEnabled {
                            HStack(spacing: 8) {
                                Text("Shortcut")
                                    .frame(width: 70, alignment: .leading)
                                ShortcutRecorderButton(flags: $voiceFlags, code: $voiceCode)
                                    .onChange(of: voiceFlags) { _, v in state.voiceHotkeyFlags = v }
                                    .onChange(of: voiceCode)  { _, v in state.voiceHotkeyCode  = v }
                                Text("hold, speak, let go → sent")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 8) {
                                Text("Language")
                                    .frame(width: 70, alignment: .leading)
                                Picker("", selection: $state.voiceLanguage) {
                                    Text("Same as the Mac").tag("auto")
                                    Text("Español (España)").tag("es-ES")
                                    Text("Español (México)").tag("es-MX")
                                    Text("English (US)").tag("en-US")
                                    Text("English (UK)").tag("en-GB")
                                    Text("Français").tag("fr-FR")
                                }
                                .labelsHidden()
                                .frame(width: 180)
                            }
                            Toggle("Read Mochi's answers aloud", isOn: $state.voiceSpeakReplies)
                            Text("Speech is transcribed on this Mac when it supports it. Mochi only listens while you hold the shortcut.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Circle().fill(voiceAllowed ? Color.green : Color.orange).frame(width: 7, height: 7)
                                Text(voiceAllowed ? "Microphone and Speech Recognition allowed"
                                                  : "macOS asks for Microphone and Speech Recognition the first time")
                                    .font(.system(size: 11))
                                Spacer()
                                if !voiceAllowed {
                                    Button("Allow now…") {
                                        Task {
                                            _ = await VoiceInput.microphoneAllowed()
                                            _ = await VoiceInput.speechAllowed()
                                            voiceAllowed = VoiceInput.permissionsGranted
                                        }
                                    }
                                }
                                Button("Check") { voiceAllowed = VoiceInput.permissionsGranted }
                            }
                        }
                    }
                    .padding(6)
                }

                // MARK: Startup
                GroupBox("Startup") {
                    Toggle("Launch at Mac startup", isOn: $launchAtStartup)
                        .onChange(of: launchAtStartup) { _, on in toggleStartup(on) }
                        .padding(6)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(statusMessage.hasPrefix("❌") ? .red : .secondary)
                        .padding(.horizontal, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 480, height: 720)
        .onAppear { checkGitHubCLI(force: false) }
    }

    // MARK: - Actions

    private var ghStatusText: String {
        switch state.githubConnection {
        case .cli(let login): return login.map { "Connected via GitHub CLI — @\($0). No token needed." }
                                     ?? "Connected via GitHub CLI. No token needed."
        case .token:          return "Connected with your Personal Access Token."
        case .failed(let why): return why
        default: break
        }
        switch ghStatus {
        case nil:        return "Looking for the GitHub CLI…"
        case .signedIn:  return state.githubCLILogin.map { "Using GitHub CLI — signed in as @\($0)" }
                                ?? "Using GitHub CLI (signed in). No token needed."
        case .signedOut: return "GitHub CLI found but signed out. Run `gh auth login`, or paste a token."
        case .missing:   return "GitHub CLI not found. Install it (brew install gh) and sign in, or paste a token."
        }
    }

    private func checkGitHubCLI(force: Bool) {
        checkingGh = true
        Task {
            let status = await Task.detached(priority: .utility) { GitHubCLI.status(force: force) }.value
            ghStatus = status
            // Re-poll so the island and this line show the real result, not just gh's sign-in.
            state.githubConnection = .checking
            GithubPoller.shared.refresh()
            try? await Task.sleep(for: .seconds(3))
            checkingGh = false
        }
    }

    private func applyCustomModel(_ value: String) {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { state.claudeModel = id }
    }

    private func toggleStartup(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            statusMessage = "❌ Startup: \(error.localizedDescription)"
            launchAtStartup = !on
        }
    }

    // MARK: - App Store: hooks via NSOpenPanel + security-scoped bookmark

    #if APPSTORE
    private func chooseClaudeFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose your .claude folder so Coucou can add its hooks"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(data, forKey: "claudeDirectoryBookmark")
                claudeAccessGranted = true
                statusMessage = "✓ .claude folder access granted."
            } catch {
                statusMessage = "❌ Bookmark error: \(error.localizedDescription)"
            }
        }
    }

    private func resolveClaudeBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "claudeDirectoryBookmark") else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            // Re-prompt user if bookmark is stale
            claudeAccessGranted = false
            UserDefaults.standard.removeObject(forKey: "claudeDirectoryBookmark")
            return nil
        }
        return url
    }

    private func installHooksAppStore() {
        guard let claudeURL = resolveClaudeBookmark() else {
            claudeAccessGranted = false
            statusMessage = "❌ .claude folder access lost — choose the folder again."
            return
        }
        do {
            let accessing = claudeURL.startAccessingSecurityScopedResource()
            defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
            pendingHookJSON = try HookServer.shared.previewClaudeHooksAppStore(claudeURL: claudeURL)
            showDiff = true
            statusMessage = "Review the JSON below before confirming."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstallAppStore() {
        guard let claudeURL = resolveClaudeBookmark() else {
            claudeAccessGranted = false
            statusMessage = "❌ .claude folder access lost."
            return
        }
        do {
            try HookServer.shared.writeClaudeHooksAppStore(claudeURL: claudeURL)
            showDiff = false
            statusMessage = "✓ Hooks installed in ~/.claude/settings.json"
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            statusMessage = "❌ Write error: \(error.localizedDescription)"
        }
    }

    private func uninstallHooksAppStore() {
        guard let claudeURL = resolveClaudeBookmark() else {
            claudeAccessGranted = false
            statusMessage = "❌ .claude folder access lost."
            return
        }
        do {
            try HookServer.shared.uninstallClaudeHooksAppStore(claudeURL: claudeURL)
            statusMessage = "✓ Hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif

    private func installHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeHooks()
            showDiff = true
            statusMessage = "Review the JSON below before confirming."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstall() {
        do {
            try HookServer.shared.writeClaudeHooks()
            showDiff = false
            statusMessage = "✓ Hooks installed in ~/.claude/settings.json"
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            statusMessage = "❌ Write error: \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            statusMessage = "✓ Hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func saveIntegrations() {
        saveKey("resend-api-key",  value: resendKey)
        saveKey("resend-from",     value: resendFrom)
        saveKey("n8n-url",         value: n8nUrl)
        saveKey("n8n-api-key",     value: n8nKey)
        saveKey("vercel-token",    value: vercelToken)
        saveKey("github-token",    value: githubToken)
        saveKey("stripe-api-key",  value: stripeKey)
        saveKey("calcom-api-key",  value: calcomKey)
        saveKey("notion-api-key",  value: notionKey)
        IntegrationRefresher.refreshAll()  // show the result now instead of at the next poll
        statusMessage = "✓ Integration keys saved."
    }

    /// Saves non-empty value; removes only if key was previously set (explicit user clear).
    private func saveKey(_ key: String, value: String) {
        if value.isEmpty {
            KeychainStore.shared.remove(key)
        } else {
            KeychainStore.shared.set(key, value: value)
        }
    }

    // MARK: - Vercel project list

    private func loadVercelProjects() {
        guard let token = KeychainStore.shared.get("vercel-token") else {
            statusMessage = "❌ Save Vercel token first."
            return
        }
        loadingVercel = true
        guard let url = URL(string: "https://api.vercel.com/v9/projects?limit=100") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let names: [String]
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let projects = json["projects"] as? [[String: Any]] {
                names = projects.compactMap { $0["name"] as? String }.sorted()
            } else {
                names = []
            }
            DispatchQueue.main.async {
                self.vercelProjects = names
                self.loadingVercel = false
                if names.isEmpty { self.statusMessage = "❌ No Vercel projects found." }
            }
        }.resume()
    }

    // MARK: - n8n workflow list

    private func loadN8nWorkflows() {
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            statusMessage = "❌ Save n8n URL and API key first."
            return
        }
        loadingN8n = true
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urls = ["\(base)/api/v1/workflows?limit=100", "\(base)/rest/workflows?limit=100"]
        fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: 0)
    }

    private func fetchN8nWorkflows(urls: [String], apiKey: String, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            DispatchQueue.main.async { self.loadingN8n = false; self.statusMessage = "❌ No n8n workflows found." }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                self.fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: idx + 1)
                return
            }
            let items: [[String: Any]]
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = obj["data"] as? [[String: Any]] { items = arr }
            else if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { items = arr }
            else { items = [] }
            let names = items.compactMap { $0["name"] as? String }.sorted()
            DispatchQueue.main.async {
                self.n8nWorkflows = names
                self.loadingN8n = false
                if names.isEmpty { self.statusMessage = "❌ No n8n workflows found." }
            }
        }.resume()
    }
}

// MARK: - Integration filter row (reusable for Vercel / n8n)

struct IntegrationFilterRow: View {
    let label: String
    let items: [String]
    @Binding var filter: Set<String>
    let loading: Bool
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button(items.isEmpty ? "Load list" : "Refresh") { onLoad() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                if !filter.isEmpty {
                    Button("Clear") { filter = [] }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundColor(.secondary)
                }
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.self) { item in
                        Toggle(item, isOn: Binding(
                            get: { filter.isEmpty || filter.contains(item) },
                            set: { on in
                                if on { filter.insert(item) }
                                else  {
                                    // First click on any item: switch from "all" to explicit set
                                    if filter.isEmpty { filter = Set(items).subtracting([item]) }
                                    else { filter.remove(item) }
                                    if filter.count == items.count { filter = [] } // all = empty
                                }
                            }
                        ))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
                if !filter.isEmpty {
                    Text("Watching \(filter.count) of \(items.count)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Shortcut recorder button

struct ShortcutRecorderButton: View {
    @Binding var flags: UInt
    @Binding var code: UInt16
    @State private var isRecording = false

    var body: some View {
        Button {
            guard !isRecording else { return }
            isRecording = true
            var token: Any?
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard !mods.isEmpty else { return event }
                DispatchQueue.main.async {
                    self.flags = mods.rawValue
                    self.code = event.keyCode
                    self.isRecording = false
                    if let t = token { NSEvent.removeMonitor(t) }
                }
                return nil
            }
        } label: {
            Text(isRecording ? "Press keys…" : shortcutLabel)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isRecording ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var shortcutLabel: String {
        let f = NSEvent.ModifierFlags(rawValue: flags)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyChar(code)
        return s.isEmpty ? "None" : s
    }

    private func keyChar(_ c: UInt16) -> String {
        let map: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 31:"O", 32:"U",
            34:"I", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M", 49:"Space", 50:"`", 27:"-"
        ]
        return map[c] ?? "·"
    }
}
