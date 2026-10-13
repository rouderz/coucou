// The main character's base in design C (with the character rail) — port of MainBaseView.swift.
// The Claude Code sessions as rows, the plan usage, then chips for the editor, Focus, the inbox
// and every integration without a character of its own.

import { h, clear, dot } from "./dom";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { assignments } from "../mochi/critters";
import { focusSession } from "../claude/sessions.ts";
import { Focus } from "../island/focus";
import type { ViewActions } from "./views";

const STATE_COLORS: Record<string, string> = {
  working: "#4C8DFF", searching: "#4C8DFF", thinking: "#A78BFA", approval: "#F5A524", question: "#F5A524",
  error: "#F4505E", ratelimit: "#F4505E", finished: "#22C55E",
};

function remaining(at: number): string {
  const m = Math.max(0, Math.round((at - Date.now()) / 60000));
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
}

function dayTime(at: number): string {
  const d = new Date(at);
  const today = new Date().toDateString() === d.toDateString();
  const hm = d.toTimeString().slice(0, 5);
  return today ? `today ${hm}` : `${d.toLocaleDateString(undefined, { weekday: "short" })} ${hm}`;
}

export function buildMainBase(actions: ViewActions): { el: HTMLElement; sync(): void } {
  const el = h("div", { class: "main-base" });
  let key = "";

  function row(color: string, title: string, detail: string, badge: string | null, run: () => void): HTMLElement {
    const r = h("button", { class: "mb-row", onclick: run }, dot(color, 7),
      h("b", { text: title }), h("span", { class: "mb-detail", text: detail }));
    if (badge) r.append(h("span", { class: "mb-badge", text: badge }));
    return r;
  }

  function chip(text: string, run: () => void, color?: string, dotColor?: string): HTMLElement {
    const c = h("button", { class: "mb-chip", onclick: run });
    if (dotColor) c.append(dot(dotColor, 6));
    c.append(h("span", { text }));
    if (color) c.style.color = color;
    return c;
  }

  function usageBar(label: string, pct: number, reset: string): HTMLElement {
    const color = pct >= 90 ? "#F4505E" : pct >= 75 ? "#F5A524" : "#4C8DFF";
    const fill = h("i", {});
    fill.style.width = `${Math.max(2, Math.min(100, pct))}%`;
    fill.style.background = color;
    return h("div", { class: "mb-usage-row" },
      h("span", { class: "mb-ulabel", text: label }), h("span", { class: "mb-bar" }, fill),
      h("b", { text: `${Math.round(pct)}%` }), h("span", { class: "mb-reset", text: reset }));
  }

  return {
    el,
    sync() {
      const own = assignments(State.settings.critterAssignments);
      const others = State.tasks.filter((t) => t.isIntegration && t.id !== "integration_claude" && !own[t.id]);
      const sessions = [...State.sessions].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 2);
      const next = JSON.stringify([
        sessions.map((s) => [s.id, s.state, s.project, s.steps.at(-1)]), !!State.pendingApproval,
        State.planUsage, State.focus.phase, State.inbox.length, State.settings.inboxEnabled,
        others.map((t) => [t.id, t.color, t.steps[0]]), Math.floor(Date.now() / 60000),
      ]);
      if (next === key) return;
      key = next;
      clear(el);

      if (!sessions.length) {
        el.append(row("#6B7079", "Claude Code", "No session right now — start one in your terminal", null, () => {}));
      }
      for (const s of sessions) {
        const waiting = s.state === "approval" && !!State.pendingApproval;
        el.append(row(STATE_COLORS[s.state] ?? "#6B7079", s.project, s.steps.at(-1) ?? s.cwd,
          waiting ? "Approve" : null, () => {
            focusSession(s.id);
            if (waiting) actions.setView("approval");
          }));
      }

      const usage = h("div", { class: "mb-usage" });
      const u = State.planUsage;
      if (u?.fiveHour) usage.append(usageBar("5h", u.fiveHour.percent, `resets in ${remaining(u.fiveHour.resetsAt)}`));
      if (u?.sevenDay) usage.append(usageBar("Week", u.sevenDay.percent, `resets ${dayTime(u.sevenDay.resetsAt)}`));
      if (!usage.childElementCount) {
        usage.append(h("div", { class: "mb-hint", text: "Hooks installed · usage shows after your next Claude message" }));
      }
      el.append(usage);

      const chips = h("div", { class: "mb-chips" });
      const claude = State.tasks.find((t) => t.id === "integration_claude");
      chips.append(chip("Open in VS Code", () => void Bridge.openInVSCode(claude?.sessionCwd ?? null)));
      if (State.focus.phase === "idle") chips.append(chip("Focus", () => Focus.start(), "#E8C27A"));
      if (State.settings.inboxEnabled && State.inbox.length) {
        chips.append(chip(`Inbox · ${State.inbox.length}`, () => actions.setView("inbox")));
      }
      for (const t of others) {
        chips.append(chip(t.steps[0] ? `${t.name} · ${t.steps[0]}` : t.name, () => actions.setFocus(t.id), undefined, t.color));
      }
      el.append(chips);
    },
  };
}
