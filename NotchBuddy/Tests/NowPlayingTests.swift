import XCTest
@testable import Coucou

/// Now playing (#107): parsing, active player and command validation. The same cases as
/// windows/src/core/nowplaying.test.ts.
final class NowPlayingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func state(_ player: NowPlayingPlayer = .music, _ st: PlaybackState = .playing,
                       position: Int? = 50_000, duration: Int? = 200_000, updatedAt: Date? = nil) -> NowPlayingState {
        NowPlayingState(player: player, state: st,
                        track: NowPlayingTrack(id: "A", title: "Song", artist: "Band", album: "LP", durationMs: duration),
                        positionMs: position, volume: 40, favorited: nil, updatedAt: updatedAt ?? t0)
    }

    func testMusicNotification() throws {
        let s = try XCTUnwrap(NowPlayingParser.parseNotification(.music, info: [
            "Player State": "Playing", "Name": "Lisztomania", "Artist": "Phoenix",
            "Album": "Wolfgang Amadeus Phoenix", "Total Time": NSNumber(value: 241_000), "Persistent ID": NSNumber(value: 123),
        ], now: t0))
        XCTAssertEqual(s.state, .playing)
        XCTAssertEqual(s.track, NowPlayingTrack(id: "123", title: "Lisztomania", artist: "Phoenix",
                                                album: "Wolfgang Amadeus Phoenix", durationMs: 241_000))
        XCTAssertNil(s.positionMs)
        XCTAssertEqual(NowPlayingParser.parseNotification(.music, info: ["Player State": "Paused", "Name": "x"], now: t0)?.state, .paused)
        let stopped = try XCTUnwrap(NowPlayingParser.parseNotification(.music, info: ["Player State": "Stopped"], now: t0))
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.track)
    }

    func testSpotifyNotification() throws {
        let s = try XCTUnwrap(NowPlayingParser.parseNotification(.spotify, info: [
            "Player State": "Playing", "Name": "Intro", "Artist": "The xx", "Album": "xx",
            "Duration": 127_000, "Playback Position": 12.5, "Track ID": "spotify:track:1",
        ], now: t0))
        XCTAssertEqual(s.track?.durationMs, 127_000)
        XCTAssertEqual(s.track?.id, "spotify:track:1")
        XCTAssertEqual(s.positionMs, 12_500)
        let other = NowPlayingParser.parseNotification(.spotify, info: ["Player State": "Playing", "Name": "x", "Total Time": 5000], now: t0)
        XCTAssertNil(other?.track?.durationMs, "Music's key means nothing to Spotify")
    }

    func testNonsenseNotificationsAreIgnored() {
        XCTAssertNil(NowPlayingParser.parseNotification(.music, info: [:], now: t0))
        XCTAssertNil(NowPlayingParser.parseNotification(.music, info: ["Player State": "Rewinding", "Name": "x"], now: t0))
        XCTAssertNil(NowPlayingParser.parseNotification(.music, info: ["Player State": "Playing", "Name": "  "], now: t0))
        let s = NowPlayingParser.parseNotification(.spotify, info: ["Player State": "Playing", "Name": "x", "Duration": -5, "Playback Position": -1], now: t0)
        XCTAssertNil(s?.positionMs)
        XCTAssertNil(s?.track?.durationMs)
        XCTAssertNil(NowPlayingParser.parseNotification(.spotify, info: ["Player State": "Playing", "Name": "x", "Duration": 1e15], now: t0)?.track?.durationMs)
        XCTAssertNil(NowPlayingParser.parseNotification(.spotify, info: ["Player State": "Playing", "Name": "x", "Duration": Double.nan], now: t0)?.track?.durationMs)
    }

    func testScriptReply() throws {
        let s = try XCTUnwrap(NowPlayingParser.parseScriptReply(.music, reply: "playing\tSong\tBand\tLP\t200000\t50500\t40\ttrue\n", now: t0))
        XCTAssertEqual(s.state, .playing)
        XCTAssertEqual(s.track?.title, "Song")
        XCTAssertEqual(s.track?.durationMs, 200_000)
        XCTAssertEqual(s.positionMs, 50_500)
        XCTAssertEqual(s.volume, 40)
        XCTAssertEqual(s.favorited, true)
        let sp = NowPlayingParser.parseScriptReply(.spotify, reply: "paused\tA\tB\tC\t0\t0\t75\t", now: t0)
        XCTAssertNil(sp?.favorited)
        XCTAssertNil(sp?.track?.durationMs)
        XCTAssertEqual(NowPlayingParser.parseScriptReply(.music, reply: "stopped\n", now: t0)?.state, .stopped)
        XCTAssertNil(NowPlayingParser.parseScriptReply(.music, reply: "playing\tonly\tthree", now: t0))
        XCTAssertNil(NowPlayingParser.parseScriptReply(.music, reply: "playing\t\tB\tC\t1\t1\t1\t", now: t0), "no title")
        XCTAssertNil(NowPlayingParser.parseScriptReply(.music, reply: "playing\tS\tB\tC\t1\t1\t900\t", now: t0)?.volume)
    }

    func testActivePlayer() {
        XCTAssertNil(NowPlayingSelector.active([:]))
        let later = t0.addingTimeInterval(10)
        let music = state(.music, .paused, updatedAt: later)
        let spotify = state(.spotify, .playing)
        XCTAssertEqual(NowPlayingSelector.active([.music: music, .spotify: spotify])?.player, .spotify, "playing wins")
        var spotifyPaused = spotify
        spotifyPaused.state = .paused
        XCTAssertEqual(NowPlayingSelector.active([.music: music, .spotify: spotifyPaused])?.player, .music, "last used")
        var musicPlaying = music
        musicPlaying.state = .playing
        XCTAssertEqual(NowPlayingSelector.active([.music: musicPlaying, .spotify: spotify])?.player, .music, "most recent of two playing")
        var tied = music
        tied.updatedAt = t0
        XCTAssertEqual(NowPlayingSelector.active([.music: tied, .spotify: spotifyPaused])?.player, .music, "tie")
        XCTAssertNil(NowPlayingSelector.active([.music: .stopped(.music, at: later)]))
        XCTAssertEqual(NowPlayingSelector.active([.music: .stopped(.music, at: later), .spotify: spotifyPaused])?.player, .spotify)
    }

    func testPositionIsExtrapolatedOnlyWhilePlaying() {
        XCTAssertEqual(state().position(at: t0.addingTimeInterval(4)), 54_000)
        XCTAssertEqual(state(.music, .paused).position(at: t0.addingTimeInterval(4)), 50_000)
        XCTAssertEqual(state().position(at: t0.addingTimeInterval(999)), 200_000)
        XCTAssertNil(state(position: nil).position(at: t0))
        XCTAssertEqual(state().position(at: t0.addingTimeInterval(-5)), 50_000, "clock going back")
    }

    func testCommandValidation() {
        let s = state()
        func v(_ c: NowPlayingCommand, _ st: NowPlayingState?, _ at: Date? = nil) -> Result<NowPlayingValidCommand, NowPlayingCommandError> {
            NowPlayingCommands.validate(c, state: st, now: at ?? t0)
        }
        XCTAssertEqual(v(.toggle, nil), .success(.toggle))
        XCTAssertEqual(v(.volume(percent: 140), nil), .success(.volume(percent: 100)))
        XCTAssertEqual(v(.volume(percent: -3), nil), .success(.volume(percent: 0)))
        XCTAssertEqual(v(.volume(percent: 33.6), nil), .success(.volume(percent: 34)))
        XCTAssertEqual(v(.volume(percent: .nan), nil), .failure(.notFinite))
        XCTAssertEqual(v(.seek(seconds: .infinity), s), .failure(.notFinite))
        XCTAssertEqual(v(.seek(seconds: 30), s), .success(.seek(positionMs: 30_000)))
        XCTAssertEqual(v(.seek(seconds: 9999), s), .success(.seek(positionMs: 200_000)))
        XCTAssertEqual(v(.seek(seconds: -4), s), .success(.seek(positionMs: 0)))
        XCTAssertEqual(v(.seek(seconds: 1e300), state(duration: nil)), .success(.seek(positionMs: 86_400_000)))
        XCTAssertEqual(v(.seek(seconds: 30), nil), .failure(.nothingPlaying))
        XCTAssertEqual(v(.seek(seconds: 30), .stopped(.music, at: t0)), .failure(.nothingPlaying))
        XCTAssertEqual(v(.skip(seconds: 10), s, t0.addingTimeInterval(2)), .success(.seek(positionMs: 62_000)))
        XCTAssertEqual(v(.skip(seconds: -10), state(position: 3_000)), .success(.seek(positionMs: 0)))
        XCTAssertEqual(v(.skip(seconds: 10), state(position: nil)), .failure(.unknownPosition))
    }

    func testScripts() {
        XCTAssertEqual(NowPlayingScripts.command(.music, .next), "tell application id \"com.apple.Music\" to next track")
        XCTAssertEqual(NowPlayingScripts.command(.spotify, .toggle), "tell application id \"com.spotify.client\" to playpause")
        XCTAssertEqual(NowPlayingScripts.command(.spotify, .previous), "tell application id \"com.spotify.client\" to previous track")
        XCTAssertEqual(NowPlayingScripts.command(.music, .seek(positionMs: 62_005)), "tell application id \"com.apple.Music\" to set player position to 62.005")
        XCTAssertEqual(NowPlayingScripts.command(.music, .seek(positionMs: 1_050)), "tell application id \"com.apple.Music\" to set player position to 1.050")
        XCTAssertEqual(NowPlayingScripts.command(.music, .volume(percent: 35)), "tell application id \"com.apple.Music\" to set sound volume to 35")
        XCTAssertTrue(NowPlayingScripts.state(.music).contains("favorited of current track"))
        XCTAssertFalse(NowPlayingScripts.state(.spotify).contains("favorited"))
        XCTAssertTrue(NowPlayingScripts.state(.spotify).hasPrefix("tell application id \"com.spotify.client\""))
    }
}
