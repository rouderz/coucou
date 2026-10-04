import { test } from "node:test";
import assert from "node:assert/strict";
import { BEAT, DanceTracker, REST_POSE, dancePose, shouldDance, trackKey } from "./dance.ts";
import type { NowPlayingState, PlaybackState, Player } from "./nowplaying.ts";
import type { BotStateName } from "./layout.ts";

// Same cases as NotchBuddy/Tests/MochiDanceTests.swift.

const near = (a: number, b: number, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} != ${b}`);

function np(state: PlaybackState, id: string | null = "A", title = "Song", player: Player = "music"): NowPlayingState {
  return {
    player, state,
    track: state === "stopped" ? null : { id, title, artist: "Band", album: "LP", durationMs: 200_000 },
    positionMs: null, volume: null, favorited: null, updatedAt: 1_000_000,
  };
}

test("dance: only when idle and allowed", () => {
  const ok = { enabled: true, playing: true, doNotDisturb: false, reduceMotion: false, state: "idle" as BotStateName };
  assert.ok(shouldDance(ok));
  assert.ok(!shouldDance({ ...ok, enabled: false }));
  assert.ok(!shouldDance({ ...ok, playing: false }));
  assert.ok(!shouldDance({ ...ok, doNotDisturb: true }));
  assert.ok(!shouldDance({ ...ok, reduceMotion: true }));
  const others: BotStateName[] = [
    "working", "thinking", "searching", "approval", "question", "error", "finished", "ratelimit", "sleeping", "dizzy",
  ];
  for (const s of others) assert.ok(!shouldDance({ ...ok, state: s }), s);
});

test("dance: the pose follows the beat", () => {
  near(BEAT, 60 / 110, 1e-12);
  // On the beat: down and squashed, upright.
  const down = dancePose(10 * BEAT, 1);
  near(down.oy, 0);
  assert.ok(down.sy < 1 && down.sx > 1);
  near(down.tilt, 0);
  // Between beats: up and stretched, leaning one way, then the other way on the next beat.
  const up = dancePose(10.5 * BEAT, 1);
  near(up.oy, -0.05);
  assert.ok(up.sy > 1);
  const next = dancePose(11.5 * BEAT, 1);
  near(up.tilt, -next.tilt);
  assert.notEqual(up.tilt, 0);
  // Gentle: never more than a small bob.
  for (let i = 0; i < 200; i++) {
    const p = dancePose(i * 0.013, 1);
    assert.ok(Math.abs(p.oy) <= 0.05 + 1e-9);
    assert.ok(Math.abs(p.tilt) <= 0.05 + 1e-9);
    assert.ok(Math.abs(p.sy - 1) <= 0.025 + 1e-9);
  }
});

test("dance: rests when off or on bad input", () => {
  assert.deepEqual(dancePose(3.3, 0), REST_POSE);
  assert.deepEqual(dancePose(Number.NaN, 1), REST_POSE);
  assert.deepEqual(dancePose(Number.POSITIVE_INFINITY, 1), REST_POSE);
  near(dancePose(10.5 * BEAT, 0.5).oy, -0.025);
  assert.deepEqual(dancePose(10.5 * BEAT, 7), dancePose(10.5 * BEAT, 1));
});

test("dance: track key", () => {
  assert.equal(trackKey(null), null);
  assert.equal(trackKey(np("stopped")), null);
  assert.equal(trackKey(np("playing", "42")), "music|42");
  assert.equal(trackKey(np("paused", null, "Hi", "spotify")), "spotify|Hi|Band");
});

test("dance: the tracker counts new songs only", () => {
  const t = new DanceTracker();
  t.apply(np("playing", "A"));
  assert.ok(t.playing);
  assert.equal(t.changes, 1);
  t.apply(np("paused", "A"));
  assert.ok(!t.playing);
  assert.equal(t.changes, 1);
  t.apply(np("playing", "A")); // resume: same song
  assert.equal(t.changes, 1);
  t.apply(np("playing", "B")); // next song
  assert.equal(t.changes, 2);
  t.apply(np("paused", "C")); // skipped while paused: no emote yet
  assert.equal(t.changes, 2);
  t.apply(np("playing", "C")); // same song starts: already seen
  assert.equal(t.changes, 2);
  t.apply(np("stopped"));
  assert.ok(!t.playing);
  assert.equal(t.key, null);
  t.apply(np("playing", "C")); // playing again after a stop
  assert.equal(t.changes, 3);
  t.apply(null);
  assert.ok(!t.playing);
});
