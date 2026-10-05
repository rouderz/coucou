// Focus timer (#119): work blocks led by Mochi. Pure state machine: no timers, no
// clock, no DND store in here. Callers pass `now` and the current Do not disturb
// value, apply the `dnd` write a step returns, and arm ONE wake-up with
// nextWakeMs() only while a block is running (0 % CPU when nothing is active).
//
// Phases: idle -> focus -> break | longBreak -> idle. A focus block that runs out
// counts as done and the break starts by itself; when a break ends we go back to
// idle ("back to work?"). Pausing is a flag on a running phase.
//
// Do not disturb: a focus block turns it on until the block's end. The value found
// at the start is kept and put back at the end (or on pause / stop / skip), unless
// the user changed DND meanwhile. If DND was already on for longer, it is left alone.
// Breaks never hold DND.
import { dndActive } from "./dnd.ts";

export type FocusPhase = "idle" | "focus" | "break" | "longBreak";

export interface FocusConfig {
  focusMin: number;
  breakMin: number;
  longBreakMin: number;
  /** A long break replaces the break after this many focus blocks. */
  blocksBeforeLong: number;
}

export const DEFAULT_FOCUS_CONFIG: FocusConfig = { focusMin: 25, breakMin: 5, longBreakMin: 15, blocksBeforeLong: 4 };

/** What a step did to Do not disturb: remember it so the end can undo it. */
export interface DndLease {
  /** DND value (epoch ms, null = off) found when the block started. */
  saved: number | null;
  /** The value we wrote, or null when we changed nothing. */
  applied: number | null;
}

export interface FocusState {
  config: FocusConfig;
  phase: FocusPhase;
  paused: boolean;
  /** Epoch ms the running phase ends; null when idle or paused. */
  endsAt: number | null;
  /** Time left while paused; null otherwise. */
  remainingMs: number | null;
  /** Length of the current phase, for the ring. */
  durationMs: number;
  /** Focus blocks finished since the last long break. */
  cycle: number;
  /** Focus blocks finished today, and the local day they belong to. */
  blocksToday: number;
  day: string;
  lease: DndLease | null;
}

export type FocusEvent = "focusStarted" | "focusDone" | "breakDone" | "paused" | "resumed" | "stopped";

export interface FocusStep {
  state: FocusState;
  /** Set Do not disturb to this (null = off); undefined = leave it as is. */
  dnd?: number | null;
  event?: FocusEvent;
}

const MIN = 60_000;

export function dayKey(now: number): string {
  const d = new Date(now);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** Keeps a config sane (whole minutes >= 1, at least one block before a long break). */
export function sanitizeConfig(c: Partial<FocusConfig> = {}): FocusConfig {
  const n = (v: number | undefined, d: number) => (typeof v === "number" && Number.isFinite(v) ? Math.max(1, Math.round(v)) : d);
  const d = DEFAULT_FOCUS_CONFIG;
  return {
    focusMin: n(c.focusMin, d.focusMin),
    breakMin: n(c.breakMin, d.breakMin),
    longBreakMin: n(c.longBreakMin, d.longBreakMin),
    blocksBeforeLong: n(c.blocksBeforeLong, d.blocksBeforeLong),
  };
}

export function initialFocus(now: number, config: Partial<FocusConfig> = {}): FocusState {
  return {
    config: sanitizeConfig(config), phase: "idle", paused: false, endsAt: null, remainingMs: null,
    durationMs: 0, cycle: 0, blocksToday: 0, day: dayKey(now), lease: null,
  };
}

export const isRunning = (s: FocusState) => s.phase !== "idle" && !s.paused;

/** Milliseconds left in the current phase (0 when idle). */
export function remainingMs(s: FocusState, now: number): number {
  if (s.phase === "idle") return 0;
  if (s.paused) return s.remainingMs ?? 0;
  return Math.max(0, (s.endsAt ?? now) - now);
}

/** 0...1 elapsed, for the ring around Mochi. */
export function progress(s: FocusState, now: number): number {
  if (s.phase === "idle" || s.durationMs <= 0) return 0;
  return Math.min(1, Math.max(0, (s.durationMs - remainingMs(s, now)) / s.durationMs));
}

/** When to wake up next: null unless a phase is running (so no timer otherwise). */
export function nextWakeMs(s: FocusState, now: number): number | null {
  return isRunning(s) && s.endsAt !== null ? Math.max(0, s.endsAt - now) : null;
}

/** "24:59": whole seconds rounded up, so it never shows 00:00 while running. */
export function formatRemaining(ms: number): string {
  const total = Math.ceil(Math.max(0, ms) / 1000);
  const m = Math.floor(total / 60);
  return `${String(m).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

function rollDay(s: FocusState, now: number): FocusState {
  const day = dayKey(now);
  return day === s.day ? s : { ...s, day, blocksToday: 0 };
}

// MARK: Do not disturb lease

function acquire(now: number, current: number | null, until: number): { lease: DndLease; dnd?: number } {
  const saved = dndActive(current, now) ? current : null;
  if (saved !== null && saved >= until) return { lease: { saved, applied: null } };
  return { lease: { saved, applied: until }, dnd: until };
}

/** Undo our write, unless nothing was written or the user changed DND since. */
function release(now: number, current: number | null, lease: DndLease | null): number | null | undefined {
  if (!lease || lease.applied === null || current !== lease.applied) return undefined;
  return dndActive(lease.saved, now) ? lease.saved : null;
}

// MARK: Transitions

function withDnd(step: FocusStep, dnd: number | null | undefined): FocusStep {
  return dnd === undefined ? step : { ...step, dnd };
}

function begin(s: FocusState, phase: Exclude<FocusPhase, "idle">, now: number, current: number | null, minutes?: number): FocusStep {
  const min = minutes ?? (phase === "focus" ? s.config.focusMin : phase === "break" ? s.config.breakMin : s.config.longBreakMin);
  const durationMs = min * MIN;
  const next: FocusState = { ...s, phase, paused: false, endsAt: now + durationMs, remainingMs: null, durationMs, lease: null };
  if (phase !== "focus") return { state: next };
  const a = acquire(now, current, next.endsAt as number);
  return withDnd({ state: { ...next, lease: a.lease } }, a.dnd);
}

function toIdle(s: FocusState): FocusState {
  return { ...s, phase: "idle", paused: false, endsAt: null, remainingMs: null, durationMs: 0, lease: null };
}

/** Starts a focus block (only from idle). `minutes` overrides the configured length for this block. */
export function start(s0: FocusState, now: number, currentDnd: number | null, minutes?: number): FocusStep {
  const s = rollDay(s0, now);
  if (s.phase !== "idle") return { state: s };
  const m = minutes === undefined ? undefined : sanitizeConfig({ focusMin: minutes }).focusMin;
  return { ...begin(s, "focus", now, currentDnd, m), event: "focusStarted" };
}

/** A focus block ran out or was skipped: break (or long break) next. */
function endFocus(s: FocusState, now: number, current: number | null, counted: boolean): FocusStep {
  const restore = release(now, current, s.lease);
  const cycle = s.cycle + (counted ? 1 : 0);
  const long = counted && cycle >= s.config.blocksBeforeLong;
  const base: FocusState = { ...s, cycle: long ? 0 : cycle, blocksToday: s.blocksToday + (counted ? 1 : 0) };
  const step = begin(base, long ? "longBreak" : "break", now, current);
  return withDnd({ ...step, event: counted ? "focusDone" : undefined }, restore);
}

/** Call when the wake-up fires (or any time: it does nothing before the end). */
export function tick(s0: FocusState, now: number, currentDnd: number | null): FocusStep {
  const s = rollDay(s0, now);
  if (!isRunning(s) || s.endsAt === null || now < s.endsAt) return { state: s };
  if (s.phase === "focus") return endFocus(s, now, currentDnd, true);
  return { state: toIdle(s), event: "breakDone" };
}

/** Skip: focus -> break (block not counted), break -> idle. */
export function skip(s0: FocusState, now: number, currentDnd: number | null): FocusStep {
  const s = rollDay(s0, now);
  if (s.phase === "idle") return { state: s };
  if (s.phase === "focus") return endFocus(s, now, currentDnd, false);
  return { state: toIdle(s), event: "breakDone" };
}

/** Stop everything; the cycle starts over. Puts DND back. */
export function stop(s0: FocusState, now: number, currentDnd: number | null): FocusStep {
  const s = rollDay(s0, now);
  if (s.phase === "idle") return { state: s };
  return withDnd({ state: { ...toIdle(s), cycle: 0 }, event: "stopped" }, release(now, currentDnd, s.lease));
}

/** Pause releases DND (a paused block shouldn't keep it on with no end). */
export function pause(s0: FocusState, now: number, currentDnd: number | null): FocusStep {
  const s = rollDay(s0, now);
  if (!isRunning(s)) return { state: s };
  const left = remainingMs(s, now);
  const state: FocusState = { ...s, paused: true, endsAt: null, remainingMs: left, lease: null };
  return withDnd({ state, event: "paused" }, s.phase === "focus" ? release(now, currentDnd, s.lease) : undefined);
}

export function resume(s0: FocusState, now: number, currentDnd: number | null): FocusStep {
  const s = rollDay(s0, now);
  if (s.phase === "idle" || !s.paused) return { state: s };
  const endsAt = now + (s.remainingMs ?? 0);
  const state: FocusState = { ...s, paused: false, endsAt, remainingMs: null };
  if (s.phase !== "focus") return { state, event: "resumed" };
  const a = acquire(now, currentDnd, endsAt);
  return withDnd({ state: { ...state, lease: a.lease }, event: "resumed" }, a.dnd);
}

/** Blocks finished today; 0 when the last one was on another day (the count only rolls over on a transition). */
export function blocksDone(s: FocusState, now: number): number {
  return s.day === dayKey(now) ? s.blocksToday : 0;
}

/** Lengths offered to start a block: the configured one, then 25 and 50. */
export function focusLengths(configured: number): number[] {
  const out = [configured];
  for (const m of [25, 50]) if (!out.includes(m)) out.push(m);
  return out;
}

export interface FocusCommand {
  minutes: number | null;
  /** Linear key, upper case ("SHO-475"). */
  issue: string | null;
}

/** Same pattern as FocusCommand.pattern in FocusTimer.swift. */
const COMMAND = /^\/?(?:focus|foco|enfoque|enf[oó]cate|concentraci[oó]n)(?:\s+(\d{1,3})\s*(?:m|min|mins|minutes?|minutos?)?)?(?:\s+(?:on|en|para|sobre|for)?\s*([a-z][a-z0-9]{0,9}-\d{1,6}))?\s*[.!]?$/i;

/**
 * "focus 50 min on SHO-475" typed in the chat (English or Spanish: "enfoque 25 min en SHO-475").
 * The minutes and the Linear key are optional; null when the text isn't a focus command.
 */
export function parseFocusCommand(text: string): FocusCommand | null {
  const m = text.trim().match(COMMAND);
  if (!m) return null;
  const minutes = m[1] === undefined ? null : Math.min(240, Math.max(1, Number(m[1])));
  return { minutes, issue: m[2] ? m[2].toUpperCase() : null };
}
