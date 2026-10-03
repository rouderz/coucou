import { test } from "node:test";
import assert from "node:assert/strict";
import {
  commandScript, parseNotification, parseScriptReply, pickActive, positionAt, stateScript, validateCommand,
  type NowPlayingState,
} from "./nowplaying.ts";

const T0 = 1_000_000;

function state(over: Partial<NowPlayingState> = {}): NowPlayingState {
  return {
    player: "music", state: "playing",
    track: { id: "A", title: "Song", artist: "Band", album: "LP", durationMs: 200_000 },
    positionMs: 50_000, volume: 40, favorited: null, updatedAt: T0, ...over,
  };
}

test("Music notification: playing, paused, stopped", () => {
  const s = parseNotification("music", {
    "Player State": "Playing", Name: "Lisztomania", Artist: "Phoenix", Album: "Wolfgang Amadeus Phoenix",
    "Total Time": 241_000, "Persistent ID": "ABCDEF0123",
  }, T0)!;
  assert.equal(s.state, "playing");
  assert.deepEqual(s.track, { id: "ABCDEF0123", title: "Lisztomania", artist: "Phoenix", album: "Wolfgang Amadeus Phoenix", durationMs: 241_000 });
  assert.equal(s.positionMs, null);
  assert.equal(parseNotification("music", { "Player State": "Paused", Name: "x" }, T0)!.state, "paused");
  const st = parseNotification("music", { "Player State": "Stopped" }, T0)!;
  assert.equal(st.state, "stopped");
  assert.equal(st.track, null);
});

test("Spotify notification: duration, position and track id", () => {
  const s = parseNotification("spotify", {
    "Player State": "Playing", Name: "Intro", Artist: "The xx", Album: "xx",
    Duration: 127_000, "Playback Position": 12.5, "Track ID": "spotify:track:1",
  }, T0)!;
  assert.equal(s.track?.durationMs, 127_000);
  assert.equal(s.track?.id, "spotify:track:1");
  assert.equal(s.positionMs, 12_500);
  // Music's "Total Time" means nothing to Spotify and vice versa.
  assert.equal(parseNotification("spotify", { "Player State": "Playing", Name: "x", "Total Time": 5000 }, T0)!.track?.durationMs, null);
});

test("notifications that make no sense are ignored", () => {
  assert.equal(parseNotification("music", {}, T0), null);
  assert.equal(parseNotification("music", { "Player State": "Rewinding", Name: "x" }, T0), null);
  assert.equal(parseNotification("music", { "Player State": "Playing", Name: "  " }, T0), null);
  assert.equal(parseNotification("spotify", { "Player State": "Playing", Name: "x", Duration: -5, "Playback Position": -1 }, T0)!.positionMs, null);
  assert.equal(parseNotification("spotify", { "Player State": "Playing", Name: "x", Duration: 1e15 }, T0)!.track?.durationMs, null);
  assert.equal(parseNotification("spotify", { "Player State": "Playing", Name: "x", Duration: NaN }, T0)!.track?.durationMs, null);
});

test("AppleScript reply", () => {
  const s = parseScriptReply("music", "playing\tSong\tBand\tLP\t200000\t50500\t40\ttrue\n", T0)!;
  assert.equal(s.state, "playing");
  assert.equal(s.track?.title, "Song");
  assert.equal(s.track?.durationMs, 200_000);
  assert.equal(s.positionMs, 50_500);
  assert.equal(s.volume, 40);
  assert.equal(s.favorited, true);
  assert.equal(parseScriptReply("spotify", "paused\tA\tB\tC\t0\t0\t75\t", T0)!.favorited, null);
  assert.equal(parseScriptReply("spotify", "paused\tA\tB\tC\t0\t0\t75\t", T0)!.track?.durationMs, null);
  assert.equal(parseScriptReply("music", "stopped\n", T0)!.state, "stopped");
  assert.equal(parseScriptReply("music", "playing\tonly\tthree", T0), null);
  assert.equal(parseScriptReply("music", "playing\t\tB\tC\t1\t1\t1\t", T0), null, "no title");
  assert.equal(parseScriptReply("music", "playing\tS\tB\tC\t1\t1\t900\t", T0)!.volume, null, "volume out of range");
});

test("the active player: playing wins, else the last used", () => {
  assert.equal(pickActive({}), null);
  const music = state({ player: "music", state: "paused", updatedAt: T0 + 10 });
  const spotify = state({ player: "spotify", state: "playing", updatedAt: T0 });
  assert.equal(pickActive({ music, spotify })!.player, "spotify");
  const spotifyPaused = { ...spotify, state: "paused" as const };
  assert.equal(pickActive({ music, spotify: spotifyPaused })!.player, "music", "last used");
  const both = pickActive({ music: { ...music, state: "playing" }, spotify })!;
  assert.equal(both.player, "music", "most recent of the two playing");
  assert.equal(pickActive({ music: { ...music, updatedAt: T0 }, spotify: { ...spotifyPaused, updatedAt: T0 } })!.player, "music", "tie");
  assert.equal(pickActive({ music: { ...music, state: "stopped", track: null } }), null);
  assert.equal(pickActive({ music: { ...music, state: "stopped", track: null }, spotify: spotifyPaused })!.player, "spotify");
});

test("position is extrapolated only while playing, never past the end", () => {
  assert.equal(positionAt(state(), T0 + 4_000), 54_000);
  assert.equal(positionAt(state({ state: "paused" }), T0 + 4_000), 50_000);
  assert.equal(positionAt(state(), T0 + 999_000), 200_000);
  assert.equal(positionAt(state({ positionMs: null }), T0), null);
  assert.equal(positionAt(state(), T0 - 5_000), 50_000, "clock going back");
});

test("command validation", () => {
  const s = state();
  assert.deepEqual(validateCommand({ kind: "toggle" }, null, T0), { ok: true, command: { kind: "toggle" } });
  assert.deepEqual(validateCommand({ kind: "volume", percent: 140 }, null, T0), { ok: true, command: { kind: "volume", percent: 100 } });
  assert.deepEqual(validateCommand({ kind: "volume", percent: -3 }, null, T0), { ok: true, command: { kind: "volume", percent: 0 } });
  assert.deepEqual(validateCommand({ kind: "volume", percent: 33.6 }, null, T0), { ok: true, command: { kind: "volume", percent: 34 } });
  assert.deepEqual(validateCommand({ kind: "volume", percent: NaN }, null, T0), { ok: false, error: "notFinite" });
  assert.deepEqual(validateCommand({ kind: "seek", seconds: Infinity }, s, T0), { ok: false, error: "notFinite" });
  assert.deepEqual(validateCommand({ kind: "seek", seconds: 30 }, s, T0), { ok: true, command: { kind: "seek", positionMs: 30_000 } });
  assert.deepEqual(validateCommand({ kind: "seek", seconds: 9999 }, s, T0), { ok: true, command: { kind: "seek", positionMs: 200_000 } });
  assert.deepEqual(validateCommand({ kind: "seek", seconds: 1e300 }, state({ track: { id: null, title: "Radio", artist: "", album: "", durationMs: null } }), T0), { ok: true, command: { kind: "seek", positionMs: 86_400_000 } });
  assert.deepEqual(validateCommand({ kind: "seek", seconds: -4 }, s, T0), { ok: true, command: { kind: "seek", positionMs: 0 } });
  assert.deepEqual(validateCommand({ kind: "seek", seconds: 30 }, null, T0), { ok: false, error: "nothingPlaying" });
  assert.deepEqual(validateCommand({ kind: "seek", seconds: 30 }, state({ state: "stopped", track: null }), T0), { ok: false, error: "nothingPlaying" });
  // +10 s / -10 s are relative to where the song is now (50 s + 2 s elapsed).
  assert.deepEqual(validateCommand({ kind: "skip", seconds: 10 }, s, T0 + 2_000), { ok: true, command: { kind: "seek", positionMs: 62_000 } });
  assert.deepEqual(validateCommand({ kind: "skip", seconds: -10 }, state({ positionMs: 3_000 }), T0), { ok: true, command: { kind: "seek", positionMs: 0 } });
  assert.deepEqual(validateCommand({ kind: "skip", seconds: 10 }, state({ positionMs: null }), T0), { ok: false, error: "unknownPosition" });
});

test("scripts address the player by bundle id and only carry validated numbers", () => {
  assert.equal(commandScript("music", { kind: "next" }), 'tell application id "com.apple.Music" to next track');
  assert.equal(commandScript("spotify", { kind: "toggle" }), 'tell application id "com.spotify.client" to playpause');
  assert.equal(commandScript("spotify", { kind: "previous" }), 'tell application id "com.spotify.client" to previous track');
  assert.equal(commandScript("music", { kind: "seek", positionMs: 62_005 }), 'tell application id "com.apple.Music" to set player position to 62.005');
  assert.equal(commandScript("music", { kind: "volume", percent: 35 }), 'tell application id "com.apple.Music" to set sound volume to 35');
  assert.match(stateScript("music"), /favorited of current track/);
  assert.doesNotMatch(stateScript("spotify"), /favorited/);
  assert.match(stateScript("spotify"), /^tell application id "com\.spotify\.client"/);
});
