import AppKit

/// Follows Music and Spotify without polling: the only triggers are their distributed
/// notifications and NSWorkspace's quit notification, so it costs nothing while nothing plays.
/// It only talks to a player (AppleScript) while that player is running, and only for a command
/// the user clicked or a refresh of the open card. No listening history is kept: `states` holds
/// the latest event per player and nothing else.
///
/// Not started anywhere yet (no pill/card): call `start()` once the card exists and the user has
/// turned the integration on. The first AppleScript call makes macOS ask for the Automation
/// permission (NSAppleEventsUsageDescription).
@MainActor
final class NowPlayingMonitor {
    static let shared = NowPlayingMonitor()

    private(set) var states: [NowPlayingPlayer: NowPlayingState] = [:]
    var active: NowPlayingState? { NowPlayingSelector.active(states) }
    /// Called after `states` changed.
    var onChange: (() -> Void)?

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        for player in NowPlayingPlayer.allCases {
            let token = distributed.addObserver(forName: player.notificationName, object: nil, queue: .main) { note in
                let parsed = NowPlayingParser.parseNotification(player, info: note.userInfo ?? [:], now: Date())
                MainActor.assumeIsolated { NowPlayingMonitor.shared.apply(player, parsed) }
            }
            observers.append((distributed, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let player = NowPlayingPlayer.allCases.first(where: { $0.bundleID == id }) else { return }
                NowPlayingMonitor.shared.apply(player, .stopped(player, at: Date()))
            }
        }
        observers.append((workspace, quit))
    }

    func stop() {
        for o in observers { o.center.removeObserver(o.token) }
        observers.removeAll()
        states.removeAll()
        onChange?()
    }

    private func apply(_ player: NowPlayingPlayer, _ new: NowPlayingState?) {
        guard var new else { return }
        let old = states[player]
        // Carry over what the notification doesn't say (volume, favorite) while it's the same song.
        if let old, old.track?.title == new.track?.title, old.track?.artist == new.track?.artist {
            new.volume = new.volume ?? old.volume
            new.favorited = new.favorited ?? old.favorited
        }
        states[player] = new
        onChange?()
    }

    static func isRunning(_ player: NowPlayingPlayer) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    /// Reads volume, favorite and exact position once (when the card opens). Does nothing, and
    /// asks nothing, if the player isn't running.
    func refresh(_ player: NowPlayingPlayer) {
        guard Self.isRunning(player),
              let reply = Self.run(NowPlayingScripts.state(player)),
              let fresh = NowPlayingParser.parseScriptReply(player, reply: reply, now: Date()) else { return }
        var merged = fresh
        if let id = states[player]?.track?.id, states[player]?.track?.title == fresh.track?.title {
            merged.track?.id = id
        }
        states[player] = merged
        onChange?()
    }

    /// Applies a click. Returns false when the player isn't running, the command is invalid or
    /// the script failed (for instance the Automation permission was refused).
    @discardableResult
    func send(_ command: NowPlayingCommand, to player: NowPlayingPlayer) -> Bool {
        guard Self.isRunning(player) else { return false }
        guard case .success(let valid) = NowPlayingCommands.validate(command, state: states[player], now: Date()) else { return false }
        guard Self.run(NowPlayingScripts.command(player, valid)) != nil else { return false }
        // Playback commands come back as notifications; the rest we reflect right away.
        if case .volume(let p) = valid { states[player]?.volume = p; onChange?() }
        return true
    }

    /// NSAppleScript isn't thread-safe: always on the main actor, and these calls are short.
    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue ?? ""
    }
}
