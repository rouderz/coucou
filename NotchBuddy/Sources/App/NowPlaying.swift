import Foundation

// MARK: - Now playing (#107)
// The port's pure logic: state parsing per player (distributed-notification userInfo and
// AppleScript replies), which player is the active one, and command validation. No I/O here, so
// it's all testable (NowPlayingTests). The Windows twin is windows/src/core/nowplaying.ts: keep
// the two in step. Nothing is stored: states live in memory and each event replaces the last.

enum NowPlayingPlayer: String, CaseIterable, Sendable {
    case music, spotify

    var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    /// The distributed notification each player posts when its state changes (the only trigger).
    var notificationName: Notification.Name {
        switch self {
        case .music: Notification.Name("com.apple.Music.playerInfo")
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }
}

enum PlaybackState: String, Sendable { case playing, paused, stopped }

struct NowPlayingTrack: Equatable, Sendable {
    /// Only used to notice a track change.
    var id: String?
    var title: String
    var artist: String
    var album: String
    var durationMs: Int?
}

struct NowPlayingState: Equatable, Sendable {
    var player: NowPlayingPlayer
    var state: PlaybackState
    var track: NowPlayingTrack?
    /// Position in ms at `updatedAt` (nil when the source doesn't say).
    var positionMs: Int?
    /// 0...100, nil when unknown.
    var volume: Int?
    /// Apple Music only.
    var favorited: Bool?
    var updatedAt: Date

    static func stopped(_ player: NowPlayingPlayer, at now: Date) -> NowPlayingState {
        NowPlayingState(player: player, state: .stopped, track: nil, positionMs: nil, volume: nil,
                        favorited: nil, updatedAt: now)
    }

    /// The position to draw now, extrapolated from the last event (no polling for the bar).
    func position(at now: Date) -> Int? {
        guard let positionMs else { return nil }
        let elapsed = state == .playing ? max(0, Int(now.timeIntervalSince(updatedAt) * 1000)) : 0
        let p = positionMs + elapsed
        if let d = track?.durationMs { return min(p, d) }
        return p
    }
}

// MARK: Parsing

enum NowPlayingParser {
    /// Nothing real lasts longer than a day: bigger numbers are garbage (and would overflow Int).
    static let maxMs = 86_400_000

    private static func state(_ raw: Any?) -> PlaybackState? {
        guard let s = raw as? String else { return nil }
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "playing": return .playing
        case "paused": return .paused
        case "stopped": return .stopped
        default: return nil
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        let d: Double?
        if let n = raw as? NSNumber { d = n.doubleValue }
        else if let s = raw as? String { d = Double(s.trimmingCharacters(in: .whitespaces)) }
        else { d = nil }
        guard let d, d.isFinite else { return nil }
        return d
    }

    private static func text(_ raw: Any?) -> String {
        (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func positiveMs(_ raw: Double?) -> Int? {
        guard let raw, raw > 0, raw <= Double(maxMs) else { return nil }
        return Int(raw.rounded())
    }

    private static func positionMs(_ raw: Double?) -> Int? {
        guard let raw, raw >= 0, raw <= Double(maxMs) else { return nil }
        return Int(raw.rounded())
    }

    /// The userInfo of `com.apple.Music.playerInfo` / `com.spotify.client.PlaybackStateChanged`.
    /// Keys as observed in the wild (neither Apple nor Spotify documents them): "Player State",
    /// "Name", "Artist", "Album"; Music: "Total Time" (ms), "Persistent ID"; Spotify: "Duration"
    /// (ms), "Playback Position" (s), "Track ID".
    static func parseNotification(_ player: NowPlayingPlayer, info: [AnyHashable: Any], now: Date) -> NowPlayingState? {
        guard let st = state(info["Player State"]) else { return nil }
        if st == .stopped { return .stopped(player, at: now) }
        let title = text(info["Name"])
        guard !title.isEmpty else { return nil }
        let idRaw = player == .music ? info["Persistent ID"] : info["Track ID"]
        var id: String?
        if let n = idRaw as? NSNumber { id = n.stringValue } else if let s = idRaw as? String, !s.isEmpty { id = s }
        let duration = positiveMs(number(player == .music ? info["Total Time"] : info["Duration"]))
        let posSec = player == .spotify ? number(info["Playback Position"]) : nil
        return NowPlayingState(
            player: player, state: st,
            track: NowPlayingTrack(id: id, title: title, artist: text(info["Artist"]), album: text(info["Album"]),
                                   durationMs: duration),
            positionMs: positionMs(posSec.map { $0 * 1000 }),
            volume: nil, favorited: nil, updatedAt: now)
    }

    /// The reply of `NowPlayingScripts.state`: "stopped", or 8 tab-separated fields: state, name,
    /// artist, album, durationMs, positionMs, volume, favorited ("" when the player has no such
    /// thing). Integers only, so the locale's decimal separator can't break it.
    static func parseScriptReply(_ player: NowPlayingPlayer, reply: String, now: Date) -> NowPlayingState? {
        var line = reply
        while line.last == "\n" || line.last == "\r" { line.removeLast() }
        if line.trimmingCharacters(in: .whitespaces).lowercased() == "stopped" { return .stopped(player, at: now) }
        let f = line.components(separatedBy: "\t")
        guard f.count == 8, let st = state(f[0]), st != .stopped else { return nil }
        let title = f[1].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let vol = number(f[6])
        let fav = f[7].trimmingCharacters(in: .whitespaces).lowercased()
        return NowPlayingState(
            player: player, state: st,
            track: NowPlayingTrack(id: nil, title: title, artist: f[2].trimmingCharacters(in: .whitespaces),
                                   album: f[3].trimmingCharacters(in: .whitespaces), durationMs: positiveMs(number(f[4]))),
            positionMs: positionMs(number(f[5])),
            volume: vol.flatMap { $0 >= 0 && $0 <= 100 ? Int($0.rounded()) : nil },
            favorited: fav == "true" ? true : fav == "false" ? false : nil,
            updatedAt: now)
    }
}

// MARK: Which player

enum NowPlayingSelector {
    /// The player to show: one playing wins (the most recent if several), else the last one used.
    /// A tie goes to the first in `NowPlayingPlayer.allCases`.
    static func active(_ states: [NowPlayingPlayer: NowPlayingState]) -> NowPlayingState? {
        let live = NowPlayingPlayer.allCases.compactMap { states[$0] }.filter { $0.state != .stopped && $0.track != nil }
        func latest(_ list: [NowPlayingState]) -> NowPlayingState? {
            var best: NowPlayingState?
            for s in list where best == nil || s.updatedAt > best!.updatedAt { best = s }
            return best
        }
        return latest(live.filter { $0.state == .playing }) ?? latest(live)
    }
}

// MARK: Commands

enum NowPlayingCommand: Equatable, Sendable {
    case play, pause, toggle, next, previous
    case seek(seconds: Double)
    /// Relative: +10 / -10 s from where the song is now.
    case skip(seconds: Double)
    case volume(percent: Double)
}

/// What is actually sent: checked, clamped, integers only.
enum NowPlayingValidCommand: Equatable, Sendable {
    case play, pause, toggle, next, previous
    case seek(positionMs: Int)
    case volume(percent: Int)
}

enum NowPlayingCommandError: Error, Equatable, Sendable {
    case notFinite, nothingPlaying, unknownPosition
}

enum NowPlayingCommands {
    /// Checks a command against the state it'll be applied to and returns the exact one to send.
    static func validate(_ cmd: NowPlayingCommand, state: NowPlayingState?, now: Date)
        -> Result<NowPlayingValidCommand, NowPlayingCommandError> {
        switch cmd {
        case .play: return .success(.play)
        case .pause: return .success(.pause)
        case .toggle: return .success(.toggle)
        case .next: return .success(.next)
        case .previous: return .success(.previous)
        case .volume(let percent):
            guard percent.isFinite else { return .failure(.notFinite) }
            return .success(.volume(percent: Int(min(100, max(0, percent.rounded())))))
        case .seek(let seconds), .skip(let seconds):
            guard seconds.isFinite else { return .failure(.notFinite) }
            guard let state, let track = state.track, state.state != .stopped else { return .failure(.nothingPlaying) }
            var target = seconds * 1000
            if case .skip = cmd {
                guard let here = state.position(at: now) else { return .failure(.unknownPosition) }
                target += Double(here)
            }
            target = max(0, min(target, Double(track.durationMs ?? NowPlayingParser.maxMs)))
            return .success(.seek(positionMs: Int(target.rounded())))
        }
    }
}

// MARK: AppleScript

/// Scripts address the player by bundle id and are only run while it's running: `tell application
/// id` would launch it otherwise, and Coucou never launches Music or Spotify.
enum NowPlayingScripts {
    private static func seconds(_ ms: Int) -> String {
        let m = max(0, ms)
        let frac = String(m % 1000)
        return "\(m / 1000)." + String(repeating: "0", count: 3 - frac.count) + frac
    }

    /// AppleScript for a validated command. Only numbers from `validate` are interpolated.
    static func command(_ player: NowPlayingPlayer, _ cmd: NowPlayingValidCommand) -> String {
        let body: String
        switch cmd {
        case .play: body = "play"
        case .pause: body = "pause"
        case .toggle: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .seek(let ms): body = "set player position to \(seconds(ms))"
        case .volume(let p): body = "set sound volume to \(p)"
        }
        return "tell application id \"\(player.bundleID)\" to \(body)"
    }

    /// Answers in the format `parseScriptReply` reads.
    static func state(_ player: NowPlayingPlayer) -> String {
        let durationMs = player == .music ? "round ((duration of current track) * 1000)" : "(duration of current track)"
        let favorited = player == .music ? "(favorited of current track) as text" : "\"\""
        return [
            "tell application id \"\(player.bundleID)\"",
            "  if player state is playing then",
            "    set st to \"playing\"",
            "  else if player state is paused then",
            "    set st to \"paused\"",
            "  else",
            "    return \"stopped\"",
            "  end if",
            "  set t to character id 9",
            "  set dur to 0",
            "  try",
            "    set dur to \(durationMs)",
            "  end try",
            "  set fav to \"\"",
            "  try",
            "    set fav to \(favorited)",
            "  end try",
            "  return st & t & (name of current track) & t & (artist of current track) & t & (album of current track) & t & (dur as integer) & t & (round ((player position) * 1000)) & t & (sound volume as integer) & t & fav",
            "end tell",
        ].joined(separator: "\n")
    }
}
