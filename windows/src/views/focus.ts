// Focus timer (#119) in the island — ports of FocusViews.swift: the controls on the
// Claude Code card and the time left. The ⏱ in the header lives in views.ts (it
// shares the pill menu); the ring around Mochi is drawn by island.ts.

import { h, svg, dot } from "./dom";
import { ICONS } from "./icons";
import { State } from "../core/state";
import { blocksDone, formatRemaining, remainingMs, type FocusState } from "../core/focus.ts";
import { Focus } from "../island/focus";

export function focusColor(f: FocusState): string {
  if (f.paused) return "#8E939C";
  return f.phase === "focus" ? "#A78BFA" : "#34D399";
}

export function focusPhaseName(f: FocusState): string {
  const name = f.phase === "break" ? "Break" : f.phase === "longBreak" ? "Long break" : "Focus";
  return f.paused ? `${name} · paused` : name;
}

/** "24:59" in every `.focus-time` under `root` (called each frame; touches the DOM once a second). */
export function syncFocusTimes(root: ParentNode) {
  if (State.focus.phase === "idle") return;
  const text = formatRemaining(remainingMs(State.focus, Date.now()));
  root.querySelectorAll<HTMLElement>(".focus-time").forEach((el) => {
    if (el.textContent !== text) el.textContent = text;
  });
}

/** What the card shows depends on these; the overview rebuilds the card when they change. */
export function focusCardKey(): string {
  const f = State.focus;
  return `${f.phase}:${f.paused}:${blocksDone(f, Date.now())}:${State.focusIssue ?? ""}`;
}

function iconButton(icon: string, title: string, onClick: () => void): HTMLElement {
  return h("button", {
    class: "icon-btn focus-icon",
    title,
    onclick: (e: Event) => {
      e.stopPropagation();
      onClick();
    },
  }, svg(icon, 8));
}

/** The running block on the Claude Code card: phase, time left, pause / skip / stop, blocks today. */
export function focusCardPanel(): HTMLElement {
  const f = State.focus;
  const head = h(
    "div",
    { class: "focus-head" },
    dot(focusColor(f), 5),
    h("b", { text: focusPhaseName(f) }),
    f.phase === "focus" && State.focusIssue ? h("span", { "data-raw": true, text: State.focusIssue }) : null,
    h("span", { class: "focus-today", text: `${blocksDone(f, Date.now())} today` }),
  );
  const row = h(
    "div",
    { class: "focus-row" },
    h("span", { class: "focus-time big", text: formatRemaining(remainingMs(f, Date.now())) }),
    iconButton(f.paused ? ICONS.play : ICONS.pause, f.paused ? "Resume" : "Pause", () => Focus.toggle()),
    iconButton(ICONS.forwardEnd, f.phase === "focus" ? "Skip to the break" : "Skip the break", () => Focus.skip()),
    iconButton(ICONS.stop, "Stop", () => Focus.stop()),
  );
  return h("div", { class: "focus-panel" }, head, row);
}

/** "⏱ Focus" in the card's action row while no block is running. */
export function focusStartButton(): HTMLElement {
  const done = blocksDone(State.focus, Date.now());
  const mins = State.focus.config.focusMin;
  return h(
    "button",
    {
      class: "link-btn focus-start",
      title: `Start a ${mins}-min focus block with Do not disturb · ${done} done today`,
      onclick: () => Focus.start(),
    },
    svg(ICONS.timer, 11),
    h("span", { text: done > 0 ? `Focus · ${done}` : "Focus" }),
  );
}
