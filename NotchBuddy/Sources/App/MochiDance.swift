import Foundation
import CoreGraphics

// MARK: - Mochi moves with the music (#117)
// Pure logic: when Mochi may dance, the bob pose at a given time, and noticing track changes.
// No I/O here, so it's all testable (MochiDanceTests). The Windows twin is
// windows/src/core/dance.ts: keep the two in step.

enum MochiDance {
    /// Players don't expose the tempo and Coucou looks nothing up online: a fixed, easy beat.
    static let bpm: Double = 110
    /// Seconds per beat.
    static var beat: Double { 60 / bpm }

    /// Offsets added to Mochi's body while dancing (fractions of R, scales, radians).
    struct Pose: Equatable, Sendable {
        var oy: CGFloat
        var sx: CGFloat
        var sy: CGFloat
        var tilt: CGFloat
        static let rest = Pose(oy: 0, sx: 1, sy: 1, tilt: 0)
    }

    /// Only an idle Mochi dances: approvals, questions, work, errors… always win. Off with the
    /// setting, while nothing plays, in Do not disturb and with Reduce Motion.
    static func shouldDance(enabled: Bool, playing: Bool, doNotDisturb: Bool, reduceMotion: Bool,
                            state: BotState) -> Bool {
        enabled && playing && !doNotDisturb && !reduceMotion && state == .idle
    }

    /// The bob at `t` seconds, scaled by `amount` (0…1, eases the dance in and out).
    /// Down on every beat (a small squash), up between beats, swaying one side per beat.
    static func pose(at t: Double, amount: CGFloat) -> Pose {
        let a = min(1, max(0, amount))
        guard a > 0, t.isFinite else { return .rest }
        let beats = t / beat
        let phase = beats - beats.rounded(.down)               // 0…1 within the beat
        let lift = CGFloat(sin(Double.pi * phase))             // 0 on the beat, 1 between
        let stretch = 2 * lift - 1                             // -1 squashed … 1 stretched
        let sway = CGFloat(sin(Double.pi * beats))             // left on odd beats, right on even
        return Pose(oy: -0.05 * lift * a,
                    sx: 1 - 0.015 * stretch * a,
                    sy: 1 + 0.025 * stretch * a,
                    tilt: 0.05 * sway * a)
    }

    /// What identifies a song: the player's id when it gives one, else title + artist.
    static func trackKey(_ s: NowPlayingState?) -> String? {
        guard let s, s.state != .stopped, let track = s.track else { return nil }
        let song: String = track.id ?? "\(track.title)|\(track.artist)"
        return "\(s.player.rawValue)|\(song)"
    }

    /// Follows the active player's state. `changes` goes up when a new song starts playing
    /// (that's the headphones emote); pausing and resuming the same song doesn't count.
    struct Tracker: Equatable, Sendable {
        var playing = false
        var key: String? = nil
        var changes = 0

        mutating func apply(_ s: NowPlayingState?) {
            playing = s?.state == .playing
            let k = MochiDance.trackKey(s)
            if playing, let k, k != key { changes += 1 }
            key = k
        }
    }
}
