import { test } from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_FOCUS_CONFIG, blocksDone, focusLengths, formatRemaining, initialFocus, parseFocusCommand, nextWakeMs, pause, progress, remainingMs, resume,
  sanitizeConfig, skip, start, stop, tick,
} from "./focus.ts";

const T0 = new Date(2026, 9, 2, 10, 0).getTime();
const MIN = 60_000;

test("focus: idle runs no timer and does nothing", () => {
  const s = initialFocus(T0);
  assert.equal(nextWakeMs(s, T0), null);
  assert.equal(remainingMs(s, T0), 0);
  for (const step of [tick(s, T0 + MIN, null), skip(s, T0, null), stop(s, T0, null), pause(s, T0, null), resume(s, T0, null)]) {
    assert.equal(step.state.phase, "idle");
    assert.equal(step.dnd, undefined);
    assert.equal(step.event, undefined);
  }
});

test("focus: a block turns DND on until its end, then break, then idle", () => {
  let step = start(initialFocus(T0), T0, null);
  assert.equal(step.state.phase, "focus");
  assert.equal(step.event, "focusStarted");
  assert.equal(step.dnd, T0 + 25 * MIN);
  assert.equal(nextWakeMs(step.state, T0), 25 * MIN);
  assert.equal(formatRemaining(remainingMs(step.state, T0 + MIN)), "24:00");
  assert.equal(progress(step.state, T0 + 5 * MIN), 0.2);

  // Too early: nothing.
  assert.equal(tick(step.state, T0 + 24 * MIN, T0 + 25 * MIN).state.phase, "focus");

  step = tick(step.state, T0 + 25 * MIN, T0 + 25 * MIN);
  assert.equal(step.event, "focusDone");
  assert.equal(step.state.phase, "break");
  assert.equal(step.state.blocksToday, 1);
  assert.equal(step.dnd, null); // DND was off before: off again
  assert.equal(nextWakeMs(step.state, T0 + 25 * MIN), 5 * MIN);

  step = tick(step.state, T0 + 30 * MIN, null);
  assert.equal(step.event, "breakDone");
  assert.equal(step.state.phase, "idle");
  assert.equal(nextWakeMs(step.state, T0 + 30 * MIN), null);
});

test("focus: the previous DND state comes back", () => {
  // Already on for 2 more hours: covers the block, left alone.
  const long = T0 + 120 * MIN;
  let step = start(initialFocus(T0), T0, long);
  assert.equal(step.dnd, undefined);
  step = tick(step.state, T0 + 25 * MIN, long);
  assert.equal(step.dnd, undefined);

  // On for 10 minutes only: extended for the block; at the end the saved value is over, so off.
  step = start(initialFocus(T0), T0, T0 + 10 * MIN);
  assert.equal(step.dnd, T0 + 25 * MIN);
  assert.equal(tick(step.state, T0 + 25 * MIN, T0 + 25 * MIN).dnd, null);

  // Skipped after 5 minutes: the saved value (until +20) is still in the future, so it is restored.
  step = start(initialFocus(T0), T0, T0 + 20 * MIN);
  assert.equal(step.dnd, T0 + 25 * MIN);
  assert.equal(skip(step.state, T0 + 5 * MIN, T0 + 25 * MIN).dnd, T0 + 20 * MIN);
});

test("focus: DND the user changed during the block is not touched", () => {
  const step = start(initialFocus(T0), T0, null);
  assert.equal(tick(step.state, T0 + 25 * MIN, null).dnd, undefined); // turned off by hand
  assert.equal(stop(step.state, T0 + MIN, T0 + 3 * 60 * MIN).dnd, undefined); // changed by hand
  assert.equal(stop(step.state, T0 + MIN, T0 + 25 * MIN).dnd, null);
});

test("focus: long break after N blocks, then the cycle starts over", () => {
  let s = initialFocus(T0, { ...DEFAULT_FOCUS_CONFIG, blocksBeforeLong: 3 });
  let now = T0;
  const seen: string[] = [];
  for (let i = 0; i < 4; i++) {
    const started = start(s, now, null);
    now += 25 * MIN;
    const ended = tick(started.state, now, now);
    seen.push(ended.state.phase);
    now += ended.state.durationMs;
    s = tick(ended.state, now, null).state;
  }
  assert.deepEqual(seen, ["break", "break", "longBreak", "break"]);
  assert.equal(s.blocksToday, 4);
  assert.equal(s.cycle, 1);
});

test("focus: pause frees DND and keeps the time; resume takes it again", () => {
  let step = start(initialFocus(T0), T0, null);
  const paused = pause(step.state, T0 + 10 * MIN, T0 + 25 * MIN);
  assert.equal(paused.state.paused, true);
  assert.equal(paused.dnd, null);
  assert.equal(nextWakeMs(paused.state, T0 + 10 * MIN), null); // no timer while paused
  assert.equal(remainingMs(paused.state, T0 + 99 * MIN), 15 * MIN);
  assert.equal(tick(paused.state, T0 + 99 * MIN, null).state.phase, "focus");

  step = resume(paused.state, T0 + 40 * MIN, null);
  assert.equal(step.state.paused, false);
  assert.equal(step.dnd, T0 + 55 * MIN);
  assert.equal(nextWakeMs(step.state, T0 + 40 * MIN), 15 * MIN);
  assert.equal(resume(step.state, T0 + 41 * MIN, null).event, undefined);
});

test("focus: pausing a break touches no DND", () => {
  const f = start(initialFocus(T0), T0, null);
  const b = tick(f.state, T0 + 25 * MIN, null).state;
  const p = pause(b, T0 + 26 * MIN, null);
  assert.equal(p.dnd, undefined);
  assert.equal(resume(p.state, T0 + 27 * MIN, null).dnd, undefined);
});

test("focus: skip and stop", () => {
  const f = start(initialFocus(T0), T0, null);
  const skipped = skip(f.state, T0 + 5 * MIN, T0 + 25 * MIN);
  assert.equal(skipped.state.phase, "break");
  assert.equal(skipped.state.blocksToday, 0); // not counted
  assert.equal(skipped.dnd, null);
  assert.equal(skip(skipped.state, T0 + 6 * MIN, null).state.phase, "idle");

  const stopped = stop(f.state, T0 + 5 * MIN, T0 + 25 * MIN);
  assert.equal(stopped.state.phase, "idle");
  assert.equal(stopped.event, "stopped");
  assert.equal(stopped.dnd, null);
  assert.equal(stopped.state.cycle, 0);
  assert.equal(start(stopped.state, T0 + 6 * MIN, null).state.phase, "focus");
});

test("focus: starting while running does nothing; custom minutes apply once", () => {
  const a = start(initialFocus(T0), T0, null, 50);
  assert.equal(a.dnd, T0 + 50 * MIN);
  assert.equal(a.state.config.focusMin, 25);
  const again = start(a.state, T0 + MIN, null, 10);
  assert.equal(again.state, a.state);
  assert.equal(again.dnd, undefined);
});

test("focus: blocks done today reset on a new day; config is sanitised", () => {
  let s = initialFocus(T0);
  s = tick(start(s, T0, null).state, T0 + 25 * MIN, null).state;
  assert.equal(s.blocksToday, 1);
  assert.equal(skip(s, T0 + 24 * 60 * MIN, null).state.blocksToday, 0);
  assert.deepEqual(sanitizeConfig({ focusMin: 0, breakMin: NaN, longBreakMin: 20.4 }),
    { focusMin: 1, breakMin: 5, longBreakMin: 20, blocksBeforeLong: 4 });
  assert.equal(formatRemaining(0), "00:00");
  assert.equal(formatRemaining(1), "00:01");
});

test("focus: blocks done today, lengths offered", () => {
  const s = tick(start(initialFocus(T0), T0, null).state, T0 + 25 * MIN, null).state;
  assert.equal(blocksDone(s, T0 + 30 * MIN), 1);
  assert.equal(blocksDone(s, T0 + 24 * 60 * MIN), 0);
  assert.deepEqual(focusLengths(25), [25, 50]);
  assert.deepEqual(focusLengths(40), [40, 25, 50]);
});

test("focus: chat command", () => {
  assert.deepEqual(parseFocusCommand("focus 50 min on SHO-475"), { minutes: 50, issue: "SHO-475" });
  assert.deepEqual(parseFocusCommand("Focus"), { minutes: null, issue: null });
  assert.deepEqual(parseFocusCommand("focus 25"), { minutes: 25, issue: null });
  assert.deepEqual(parseFocusCommand("focus 45m"), { minutes: 45, issue: null });
  assert.deepEqual(parseFocusCommand("/focus sho-12"), { minutes: null, issue: "SHO-12" });
  assert.deepEqual(parseFocusCommand("enfoque 30 minutos en ABC-9."), { minutes: 30, issue: "ABC-9" });
  assert.deepEqual(parseFocusCommand("  focus 999 min  "), { minutes: 240, issue: null });
  assert.equal(parseFocusCommand("focus on the login bug"), null);
  assert.equal(parseFocusCommand("focusing is hard"), null);
  assert.equal(parseFocusCommand("how do I focus 50 min?"), null);
});
