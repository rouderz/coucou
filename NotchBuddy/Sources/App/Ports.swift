import Foundation

// MARK: - Ports (#17)
// Interfaces only where there's real variation: agents (Claude Code, Codex), integrations,
// where secrets live (Keychain here, Credential Manager on Windows) and the hook transport
// (HookTransport.swift). Each platform brings its adapters; the rest of the app uses the port.

// MARK: Secrets

protocol SecretStore: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, value: String)
    func remove(_ key: String)
}

extension KeychainStore: SecretStore {}

/// For tests and previews: nothing leaves memory.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()

    init(_ values: [String: String] = [:]) { self.values = values }

    func get(_ key: String) -> String? { lock.withLock { values[key] } }
    func set(_ key: String, value: String) { lock.withLock { values[key] = value } }
    func remove(_ key: String) { lock.withLock { values[key] = nil } }
}

enum Secrets {
    /// Where API keys and tokens are kept. Swapped only by tests.
    nonisolated(unsafe) static var store: any SecretStore = KeychainStore.shared
}

// MARK: Integrations

/// Something Coucou polls and shows on a card (GitHub, Vercel, Stripe…).
@MainActor
protocol IntegrationSource: AnyObject {
    /// The card's task id, e.g. "integration_github".
    var integrationID: String { get }
    func start()
    func pollNow()
}

extension GithubPoller: IntegrationSource { var integrationID: String { "integration_github" } }
extension NotionPoller: IntegrationSource { var integrationID: String { "integration_notion" } }
extension LinearPoller: IntegrationSource { var integrationID: String { "integration_linear" } }
extension VercelPoller: IntegrationSource { var integrationID: String { "integration_vercel" } }
extension ResendPoller: IntegrationSource { var integrationID: String { "integration_resend" } }
extension N8nPoller: IntegrationSource { var integrationID: String { "integration_n8n" } }
extension StripePoller: IntegrationSource { var integrationID: String { "integration_stripe" } }
extension CalcomPoller: IntegrationSource { var integrationID: String { "integration_calcom" } }
extension GmailPoller: IntegrationSource { var integrationID: String { "integration_gmail" } }
extension PlanUsagePoller: IntegrationSource { var integrationID: String { "integration_claude" } }

@MainActor
enum Integrations {
    static let all: [any IntegrationSource] = [
        GithubPoller.shared, NotionPoller.shared, LinearPoller.shared, VercelPoller.shared,
        ResendPoller.shared, N8nPoller.shared, StripePoller.shared, CalcomPoller.shared,
        GmailPoller.shared, PlanUsagePoller.shared,
    ]

    static func source(_ id: String) -> (any IntegrationSource)? {
        all.first { $0.integrationID == id }
    }
}

// MARK: Agents

enum CodingAgentHookState: Equatable { case unavailable, notInstalled, needsUpdate, installed }

/// A coding agent whose sessions Coucou follows through hooks.
@MainActor
protocol CodingAgent {
    /// Matches the "agent" field nb-hook adds to events ("claude" when absent).
    var id: String { get }
    var name: String { get }
    var hookState: CodingAgentHookState { get }
    func installHooks() throws
    func uninstallHooks() throws
}

struct ClaudeCodeAgent: CodingAgent {
    let id = "claude"
    let name = "Claude Code"

    var hookState: CodingAgentHookState {
        switch HookServer.installState() {
        case .installed: return .installed
        case .needsUpdate: return .needsUpdate
        case .notInstalled: return .notInstalled
        }
    }

    func installHooks() throws {
        _ = try HookServer.shared.previewClaudeHooks()
        try HookServer.shared.writeClaudeHooks()
    }

    func uninstallHooks() throws { try HookServer.shared.uninstallClaudeHooks() }
}

#if !APPSTORE
struct CodexAgent: CodingAgent {
    let id = "codex"
    let name = "Codex"

    var hookState: CodingAgentHookState {
        switch CodexHooks.state() {
        case .noCodex: return .unavailable
        case .notInstalled: return .notInstalled
        case .installed: return .installed
        }
    }

    func installHooks() throws { try CodexHooks.install() }
    func uninstallHooks() throws { try CodexHooks.uninstall() }
}
#endif

@MainActor
enum Agents {
    static var all: [any CodingAgent] {
        #if APPSTORE
        return [ClaudeCodeAgent()]
        #else
        return [ClaudeCodeAgent(), CodexAgent()]
        #endif
    }

    static func named(_ id: String) -> (any CodingAgent)? { all.first { $0.id == id } }
}
