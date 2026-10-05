import XCTest
@testable import Coucou

/// Mochi moves with the music (#117): when it dances, the bob, and track changes. The same cases
/// as windows/src/core/dance.test.ts.
final class MochiDanceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func np(_ st: PlaybackState, id: String? = "A", title: String = "Song",
                    player: NowPlayingPlayer = .music) -> NowPlayingState {
        NowPlayingState(player: player, state: st,
                        track: st == .stopped ? nil : NowPlayingTrack(id: id, title: title, artist: "Band", album: "LP", durationMs: 200_000),
                        positionMs: nil, volume: nil, favorited: nil, updatedAt: t0)
    }

    func testShouldDanceOnlyWhenIdleAndAllowed() {
        XCTAssertTrue(MochiDance.shouldDance(enabled: true, playing: true, doNotDisturb: false, reduceMotion: false, state: .idle))
        XCTAssertFalse(MochiDance.shouldDance(enabled: false, playing: true, doNotDisturb: false, reduceMotion: false, state: .idle))
        XCTAssertFalse(MochiDance.shouldDance(enabled: true, playing: false, doNotDisturb: false, reduceMotion: false, state: .idle))
        XCTAssertFalse(MochiDance.shouldDance(enabled: true, playing: true, doNotDisturb: true, reduceMotion: false, state: .idle))
        XCTAssertFalse(MochiDance.shouldDance(enabled: true, playing: true, doNotDisturb: false, reduceMotion: true, state: .idle))
        for s in BotState.allCases where s != .idle {
            XCTAssertFalse(MochiDance.shouldDance(enabled: true, playing: true, doNotDisturb: false, reduceMotion: false, state: s), "\(s)")
        }
    }

    func testPoseFollowsTheBeat() {
        let beat = MochiDance.beat
        XCTAssertEqual(beat, 60.0 / 110, accuracy: 1e-9)
        // On the beat: down and squashed, upright.
        let down = MochiDance.pose(at: 10 * beat, amount: 1)
        XCTAssertEqual(down.oy, 0, accuracy: 1e-6)
        XCTAssertLessThan(down.sy, 1)
        XCTAssertGreaterThan(down.sx, 1)
        XCTAssertEqual(down.tilt, 0, accuracy: 1e-6)
        // Between beats: up and stretched, leaning one way, then the other way on the next beat.
        let up = MochiDance.pose(at: 10.5 * beat, amount: 1)
        XCTAssertEqual(up.oy, -0.05, accuracy: 1e-6)
        XCTAssertGreaterThan(up.sy, 1)
        let next = MochiDance.pose(at: 11.5 * beat, amount: 1)
        XCTAssertEqual(up.tilt, -next.tilt, accuracy: 1e-6)
        XCTAssertNotEqual(up.tilt, 0)
        // Gentle: never more than a small bob.
        for i in 0..<200 {
            let p = MochiDance.pose(at: Double(i) * 0.013, amount: 1)
            XCTAssertLessThanOrEqual(abs(p.oy), 0.05 + 1e-9)
            XCTAssertLessThanOrEqual(abs(p.tilt), 0.05 + 1e-9)
            XCTAssertLessThanOrEqual(abs(p.sy - 1), 0.025 + 1e-9)
        }
    }

    func testPoseRestsWhenOffOrBadInput() {
        XCTAssertEqual(MochiDance.pose(at: 3.3, amount: 0), .rest)
        XCTAssertEqual(MochiDance.pose(at: .nan, amount: 1), .rest)
        XCTAssertEqual(MochiDance.pose(at: .infinity, amount: 1), .rest)
        let half = MochiDance.pose(at: 10.5 * MochiDance.beat, amount: 0.5)
        XCTAssertEqual(half.oy, -0.025, accuracy: 1e-6)
        XCTAssertEqual(MochiDance.pose(at: 10.5 * MochiDance.beat, amount: 7), MochiDance.pose(at: 10.5 * MochiDance.beat, amount: 1))
    }

    func testTrackKey() {
        XCTAssertNil(MochiDance.trackKey(nil))
        XCTAssertNil(MochiDance.trackKey(np(.stopped)))
        XCTAssertEqual(MochiDance.trackKey(np(.playing, id: "42")), "music|42")
        XCTAssertEqual(MochiDance.trackKey(np(.paused, id: nil, title: "Hi", player: .spotify)), "spotify|Hi|Band")
    }

    func testTrackerCountsNewSongsOnly() {
        var t = MochiDance.Tracker()
        t.apply(np(.playing, id: "A"))
        XCTAssertTrue(t.playing); XCTAssertEqual(t.changes, 1)
        t.apply(np(.paused, id: "A"))
        XCTAssertFalse(t.playing); XCTAssertEqual(t.changes, 1)
        t.apply(np(.playing, id: "A"))   // resume: same song
        XCTAssertEqual(t.changes, 1)
        t.apply(np(.playing, id: "B"))   // next song
        XCTAssertEqual(t.changes, 2)
        t.apply(np(.paused, id: "C"))    // skipped while paused: no emote yet
        XCTAssertEqual(t.changes, 2)
        t.apply(np(.playing, id: "C"))   // same song starts: already seen
        XCTAssertEqual(t.changes, 2)
        t.apply(np(.stopped))
        XCTAssertFalse(t.playing); XCTAssertNil(t.key)
        t.apply(np(.playing, id: "C"))   // playing again after a stop
        XCTAssertEqual(t.changes, 3)
        t.apply(nil)
        XCTAssertFalse(t.playing)
    }
}
