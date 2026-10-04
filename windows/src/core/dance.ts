// Mochi moves with the music (#117): pure logic — when Mochi may dance, the bob pose at a given
// time, and noticing track changes. No I/O here. The macOS twin is MochiDance.swift and the two
// must agree (same cases in the tests).
//
// Windows / Linux have no music source yet (nowplaying.ts only knows the macOS players), so
// `State.musicPlaying` stays false until one is wired (GSMTC / MPRIS, #107); the animation is
// ready for it.

import type { BotStateName } from "./layout";
import type { NowPlayingState } from "./nowplaying";

/** Players don't expose the tempo and Coucou looks nothing up online: a fixed, easy beat. */
export const DANCE_BPM = 110;
/** Seconds per beat. */
export const BEAT = 60 / DANCE_BPM;

/** Offsets added to Mochi's body while dancing (fractions of R, scales, radians). */
export interface DancePose {
  oy: number;
  sx: number;
  sy: number;
  tilt: number;
}

export const REST_POSE: Readonly<DancePose> = { oy: 0, sx: 1, sy: 1, tilt: 0 };

/**
 * Only an idle Mochi dances: approvals, questions, work, errors… always win. Off with the
 * setting, while nothing plays, in Do not disturb and with reduced motion.
 */
export function shouldDance(o: {
  enabled: boolean;
  playing: boolean;
  doNotDisturb: boolean;
  reduceMotion: boolean;
  state: BotStateName;
}): boolean {
  return o.enabled && o.playing && !o.doNotDisturb && !o.reduceMotion && o.state === "idle";
}

/**
 * The bob at `t` seconds, scaled by `amount` (0…1, eases the dance in and out).
 * Down on every beat (a small squash), up between beats, swaying one side per beat.
 */
export function dancePose(t: number, amount: number): DancePose {
  const a = Math.min(1, Math.max(0, amount));
  if (!(a > 0) || !Number.isFinite(t)) return { ...REST_POSE };
  const beats = t / BEAT;
  const phase = beats - Math.floor(beats); // 0…1 within the beat
  const lift = Math.sin(Math.PI * phase); // 0 on the beat, 1 between
  const stretch = 2 * lift - 1; // -1 squashed … 1 stretched
  const sway = Math.sin(Math.PI * beats); // one side per beat
  return {
    oy: -0.05 * lift * a,
    sx: 1 - 0.015 * stretch * a,
    sy: 1 + 0.025 * stretch * a,
    tilt: 0.05 * sway * a,
  };
}

/** What identifies a song: the player's id when it gives one, else title + artist. */
export function trackKey(s: NowPlayingState | null): string | null {
  if (!s || s.state === "stopped" || !s.track) return null;
  return `${s.player}|${s.track.id ?? `${s.track.title}|${s.track.artist}`}`;
}

/**
 * Follows the active player's state. `changes` goes up when a new song starts playing (that's
 * the headphones emote); pausing and resuming the same song doesn't count.
 */
export class DanceTracker {
  playing = false;
  key: string | null = null;
  changes = 0;

  apply(s: NowPlayingState | null) {
    this.playing = s?.state === "playing";
    const k = trackKey(s);
    if (this.playing && k !== null && k !== this.key) this.changes += 1;
    this.key = k;
  }
}
