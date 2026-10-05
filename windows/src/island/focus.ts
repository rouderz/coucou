// Focus timer (#119): runs the pure state machine in core/focus.ts for the island,
// like FocusTimer in FocusTimer.swift. One setTimeout, armed only while a block or
// a break is running (nothing at all when idle or paused), applies the Do not
// disturb writes a step asks for, and shows the prompt at the end of a block or a break.

import { Bridge, onEvent } from "../core/bridge";
import { dndActive } from "../core/dnd.ts";
import * as F from "../core/focus.ts";
import { t } from "../core/i18n.ts";
import { Sound } from "../core/sound";
import { State, type FocusNote } from "../core/state";
import type { Island } from "./island";

let timer: number | null = null;
let islandRef: Island | null = null;

/** Do not disturb as the state machine needs it: the end time, or null when off. */
function current(): number | null {
  const until = State.settings.dndUntil;
  return dndActive(until) ? until : null;
}

function apply(step: F.FocusStep, announce = false) {
  State.focus = step.state;
  if (step.dnd !== undefined) {
    State.settings.dndUntil = step.dnd;
    void Bridge.saveSettings(State.settings);
  }
  if (step.event) {
    void Bridge.log(`focus ${step.event}`);
    if (announce) announceEvent(step.event);
  }
  rearm();
  State.notify();
}

/** Exactly one timer while a phase runs, none otherwise (0 % CPU when idle or paused). */
function rearm() {
  if (timer !== null) window.clearTimeout(timer);
  timer = null;
  const wait = F.nextWakeMs(State.focus, Date.now());
  if (wait === null) return;
  timer = window.setTimeout(() => {
    timer = null;
    apply(F.tick(State.focus, Date.now(), current()), true);
  }, wait + 50);
}

/** End of a block or a break: a soft sound and the next step as a prompt in the island. */
function announceEvent(event: F.FocusEvent) {
  let note: FocusNote;
  if (event === "focusDone") {
    const mins = Math.round(State.focus.durationMs / 60_000);
    note = {
      kind: "blockDone",
      text: State.focus.phase === "longBreak" ? `Nice run! Long break, ${mins} min?` : `Block done! Break, ${mins} min?`,
    };
    Sound.play("proud");
    islandRef?.emote("proud");
  } else if (event === "breakDone") {
    note = { kind: "breakDone", text: "Break's over. Back to work?" };
    Sound.play("pop");
  } else {
    return;
  }
  // An approval on screen keeps the island; Do not disturb (the user's own) keeps it closed.
  if (State.pendingApproval) return;
  State.focusNote = note;
  State.noteMessage = note.text;
  if (dndActive(State.settings.dndUntil)) return;
  islandRef?.alert("note");
}

export const Focus = {
  /** `issue`: a Linear key shown with the block; kept for the next blocks until Stop. */
  start(minutes?: number, issue?: string | null) {
    if (issue) State.focusIssue = issue;
    apply(F.start(State.focus, Date.now(), current(), minutes));
  },
  pause() {
    apply(F.pause(State.focus, Date.now(), current()));
  },
  resume() {
    apply(F.resume(State.focus, Date.now(), current()));
  },
  skip() {
    apply(F.skip(State.focus, Date.now(), current()));
  },
  stop() {
    State.focusIssue = null;
    apply(F.stop(State.focus, Date.now(), current()));
  },
  /** The shortcut and a click on the header timer: start, pause or resume. */
  toggle() {
    const f = State.focus;
    if (f.phase === "idle") Focus.start();
    else if (f.paused) Focus.resume();
    else Focus.pause();
  },
  /** "Keep working": no break (or the rest of it), the next block now. */
  keepWorking(minutes?: number, issue?: string | null) {
    const f = State.focus;
    if (f.phase === "break" || f.phase === "longBreak") apply(F.skip(f, Date.now(), current()));
    Focus.start(minutes, issue);
  },
  /** A focus command typed in the chat; returns Mochi's answer (already translated). */
  run(command: F.FocusCommand): string {
    if (State.focus.phase === "focus") {
      const left = F.formatRemaining(F.remainingMs(State.focus, Date.now()));
      return t(`A focus block is already running (${left} left).`);
    }
    Focus.keepWorking(command.minutes ?? undefined, command.issue);
    const mins = Math.round(State.focus.durationMs / 60_000);
    return State.focusIssue
      ? t(`Focus: ${mins} min on ${State.focusIssue}. Do not disturb is on until the end of the block.`)
      : t(`Focus: ${mins} min. Do not disturb is on until the end of the block.`);
  },
};

/** Block lengths from Settings → Focus (at launch and whenever they change). */
export function applyFocusSettings() {
  const s = State.settings;
  State.focus = {
    ...State.focus,
    config: F.sanitizeConfig({
      focusMin: s.focusMin, breakMin: s.breakMin, longBreakMin: s.longBreakMin, blocksBeforeLong: s.blocksBeforeLong,
    }),
  };
  void Bridge.focusShortcut(s.focusShortcut !== false);
}

export function registerFocus(island: Island) {
  islandRef = island;
  applyFocusSettings();
  void onEvent<null>("focus-shortcut", () => Focus.toggle());
}
