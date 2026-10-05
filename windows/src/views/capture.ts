// Quick capture view (#118) — DOM port of QuickCaptureView.swift: one line in the
// island becomes a Linear issue. The rules live in core/capture.ts (`reduce`); this
// runs its effects and draws it. Nothing is sent to Linear before the second Enter /
// the Create click. The requests themselves go through Rust (linear.rs).

import { h, clear, dot } from "./dom";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { Sound } from "../core/sound";
import {
  reduce, parseCapture, parseTeams, parseIssueCreate, buildIssueCreateVariables, branchToCopy,
  type CaptureState, type CaptureEvent, type CaptureAttachment, type ChipProblem, type PreviewChip, type TeamInfo,
} from "../core/capture";
import type { ViewActions, ViewHost } from "./views";

interface CaptureStore {
  flow: CaptureState;
  teams: TeamInfo[];
  viewerId: string | null;
  teamsError: string | null;
  loadingTeams: boolean;
  teamsAt: number;
  /** What can go into the description: the editor's context, or a chat answer. */
  attachment: CaptureAttachment | null;
  /** Only sent when on: off for captured context (one click attaches it), on for a chat answer. */
  attach: boolean;
  copied: boolean;
}

export const Capture: CaptureStore = {
  flow: { phase: "editing", line: "" },
  teams: [],
  viewerId: null,
  teamsError: null,
  loadingTeams: false,
  teamsAt: 0,
  attachment: null,
  attach: false,
  copied: false,
};

const TEAMS_TTL_MS = 10 * 60_000;
let closeIsland: () => void = () => {};

function errText(err: unknown): string {
  return String(err).replace(/^Error:\s*/, "");
}

export function captureBusy(): boolean {
  return Capture.flow.phase === "creating" || Capture.flow.phase === "done";
}

/** A fresh input, optionally prefilled. Never sends anything. */
export function beginCapture(line = "", attachment: CaptureAttachment | null = null, attach = false) {
  Capture.flow = { phase: "editing", line };
  Capture.attachment = attachment;
  Capture.attach = attach && attachment != null;
  Capture.copied = false;
  void loadTeams();
  State.notify();
}

/** Teams (and your user id for "@me"), kept 10 minutes. Read-only. */
export async function loadTeams(force = false): Promise<void> {
  if (!force && Capture.teams.length && Date.now() - Capture.teamsAt < TEAMS_TTL_MS) return;
  if (Capture.loadingTeams) return;
  Capture.loadingTeams = true;
  State.notify();
  try {
    const { viewerId, teams } = parseTeams(await Bridge.linearTeams());
    Capture.teams = teams;
    Capture.viewerId = viewerId;
    Capture.teamsError = null;
    Capture.teamsAt = Date.now();
    // A preview drawn before the teams arrived is drawn again; this never confirms it.
    if (Capture.flow.phase === "preview") {
      Capture.flow = { phase: "editing", line: Capture.flow.line };
      sendCapture({ type: "enter" });
    }
  } catch (err) {
    Capture.teamsError = errText(err);
  } finally {
    Capture.loadingTeams = false;
    State.notify();
  }
}

export function sendCapture(e: CaptureEvent) {
  const { state, effect } = reduce(Capture.flow, e, {
    teams: Capture.teams,
    defaultTeamKey: State.settings.linearDefaultTeam || null,
    now: new Date(),
  });
  Capture.flow = state;
  if (effect?.type === "create") void create(effect.chip);
  else if (effect?.type === "close") close();
  State.notify();
}

function close() {
  Capture.flow = { phase: "editing", line: "" };
  Capture.attachment = null;
  Capture.attach = false;
  closeIsland();
}

/** Only reached from the "create" effect, i.e. the second Enter / the Create click. */
async function create(chip: PreviewChip) {
  try {
    const description = Capture.attach ? Capture.attachment?.text ?? null : null;
    const { input } = buildIssueCreateVariables(chip, Capture.viewerId, description);
    const issue = parseIssueCreate(await Bridge.linearCreateIssue(input));
    if (!issue) throw new Error("Linear didn't accept the issue");
    sendCapture({ type: "created", issue });
    Sound.play("finish");
    void Bridge.refreshIntegration("integration_linear");
  } catch (err) {
    sendCapture({ type: "failed", message: errText(err) });
    Sound.play("error");
  }
}

function problemText(problem: ChipProblem, line: string): string {
  switch (problem) {
    case "empty-title":
      return "Write a title";
    case "unknown-team":
      return `No team with the key ${parseCapture(line).teamKey ?? State.settings.linearDefaultTeam.toUpperCase()}`;
    case "no-team":
      return "Add #TEAM or pick a default team in Settings";
    case "no-teams-loaded":
      return Capture.teamsError ?? (Capture.loadingTeams ? "Loading your Linear teams…" : "No Linear teams loaded");
  }
}

function hintText(): string {
  const f = Capture.flow;
  switch (f.phase) {
    case "editing": return "#TEAM · p1–p4 · @me · !fri — Enter to preview";
    case "preview": return f.chip.ready ? "Enter again to create · Esc to edit" : "Fix the line, then Enter";
    case "creating": return "Creating…";
    case "done": return "Created · Enter to close";
    case "failed": return "Enter to try again";
  }
}

/** Team · title · priority · assignee · due date, as Linear would get them. */
function chipEl(chip: PreviewChip): HTMLElement {
  return h("span", { class: "qc-chip" },
    h("b", { class: chip.team ? "" : "warn", text: chip.team?.key ?? "?", "data-raw": true }),
    chip.title ? h("span", { class: "qc-title", text: chip.title, "data-raw": true }) : null,
    chip.priority > 0 ? h("span", { text: chip.priorityLabel }) : null,
    chip.assignee ? h("span", { text: "Me" }) : null,
    chip.dueDate ? h("span", { text: `Due ${chip.dueDate}` }) : null,
  );
}

function smallBtn(label: string, primary: boolean, onClick: () => void, title?: string): HTMLElement {
  return h("button", { class: primary ? "qc-btn primary" : "qc-btn", text: label, title, onclick: onClick });
}

export function buildCapture(actions: ViewActions): ViewHost {
  closeIsland = () => actions.collapse();

  const hint = h("span", { class: "qc-hint" });
  // "+ app.ts:42": click to put the context in the description (off until clicked).
  const attachBtn = h("button", { class: "chip-attach qc-attach" });
  attachBtn.addEventListener("click", () => {
    Capture.attach = !Capture.attach;
    State.notify();
  });
  const head = h("div", { class: "qc-head" },
    dot("#5E6AD2", 7), h("b", { text: "New Linear issue" }), hint, h("div", { style: "flex:1" }), attachBtn);
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Fix the cart total #SHO p2 @me !fri",
    spellcheck: "false",
  }) as HTMLInputElement;
  const bottom = h("div", { class: "qc-bottom" });
  const card = h("div", { class: "card wash qc-card" },
    h("div", { class: "qc-body" }, head, h("div", { class: "chat-bar" }, input), bottom));
  card.style.setProperty("--wash", "rgba(99,102,241,0.5)");
  const el = h("div", { class: "view" }, card);

  input.addEventListener("input", () => {
    // While creating / once created the line is fixed.
    if (captureBusy()) input.value = Capture.flow.line;
    else sendCapture({ type: "type", line: input.value });
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      sendCapture({ type: "enter" });
    } else if (e.key === "Escape") {
      e.preventDefault();
      sendCapture({ type: "escape" });
    }
    e.stopPropagation(); // the flow decides what Escape does
  });

  let drawn = "";

  function drawBottom() {
    const f = Capture.flow;
    clear(bottom);
    switch (f.phase) {
      case "editing":
        break;
      case "preview": {
        bottom.append(chipEl(f.chip));
        const problem = f.chip.problems[0];
        if (problem) bottom.append(h("span", { class: "qc-problem", text: problemText(problem, f.line) }));
        bottom.append(h("div", { style: "flex:1" }));
        if (f.chip.ready) bottom.append(smallBtn("Create", true, () => sendCapture({ type: "enter" })));
        break;
      }
      case "creating":
        bottom.append(chipEl(f.chip), h("span", { class: "qc-hint", text: "Creating…" }));
        break;
      case "done": {
        const issue = f.issue;
        bottom.append(
          h("span", { class: "qc-ok", text: "✓" }),
          h("b", { class: "qc-id", text: issue.identifier, "data-raw": true }),
          h("span", { class: "qc-title", text: issue.title, "data-raw": true }),
          h("div", { style: "flex:1" }),
          smallBtn("Open", true, () => actions.openUrl(issue.url)),
          smallBtn(Capture.copied ? "Copied" : "Copy branch name", false, () => {
            void navigator.clipboard.writeText(branchToCopy(issue));
            Capture.copied = true;
            State.notify();
          }, branchToCopy(issue)),
        );
        break;
      }
      case "failed":
        bottom.append(h("span", { class: "qc-problem err", text: f.message }));
        break;
    }
  }

  return {
    el,
    sync() {
      if (input.value !== Capture.flow.line) input.value = Capture.flow.line;
      hint.textContent = hintText();
      const a = Capture.attachment;
      attachBtn.style.display = a && !captureBusy() ? "" : "none";
      if (a) {
        attachBtn.textContent = `${Capture.attach ? "📎" : "+"} ${a.label}`;
        attachBtn.classList.toggle("on", Capture.attach);
        attachBtn.title = Capture.attach ? "Attached to the description · click to remove" : "Click to add this to the description";
      }
      const key = JSON.stringify([Capture.flow, Capture.copied, Capture.teamsError, Capture.loadingTeams]);
      if (key !== drawn) {
        drawn = key;
        drawBottom();
      }
    },
    focus() {
      input.focus();
      const end = input.value.length;
      input.setSelectionRange(end, end);
    },
  };
}
