// Several Claude Code / Codex sessions at once (#24 on macOS, HookServer.routeSession).
// The focused session drives the Claude card; the others keep their own record,
// show as chips, and take the card over when the focused one goes quiet.

import { State, type ClaudeSession } from "../core/state";
import type { BotStateName } from "../core/layout";
import { stepLabel, stopMessage } from "./labels.ts";
import { forget } from "./timeline.ts";
import { Sound } from "../core/sound";

export const CLAUDE_ID = "integration_claude";

const QUIET: BotStateName[] = ["idle", "finished", "error"];
const STALE_MS = 30 * 60 * 1000;

function card() {
  return State.tasks.find((t) => t.id === CLAUDE_ID) ?? null;
}

/** Copies the card (steps, state) back into the focused session's record. */
export function syncFocused() {
  const id = State.focusedSession;
  const s = State.sessions.find((x) => x.id === id);
  const task = card();
  if (!s || !task) return;
  s.steps = [...task.steps];
  s.state = task.state;
}

/** Puts a session on the card (from a chip, an approval, or automatically). */
export function focusSession(id: string) {
  const s = State.sessions.find((x) => x.id === id);
  if (!s) return;
  syncFocused();
  State.focusedSession = id;
  s.unseen = false;
  const task = card();
  if (task) {
    task.name = s.project;
    task.sessionCwd = s.cwd || task.sessionCwd;
    task.steps = [...s.steps];
    task.stepIndex = Math.max(0, s.steps.length - 1);
    task.state = s.state;
  }
  State.notify();
}

function prune(now: number) {
  State.sessions = State.sessions.filter(
    (s) => s.id === State.focusedSession || now - s.updatedAt < STALE_MS,
  );
}

/**
 * Records the session and says whether this event drives the card: the focused
 * session does; another one takes over when the focused one is quiet and it
 * starts working.
 */
export function routeSession(
  id: string, agent: string, project: string, cwd: string, event: string, now = Date.now(),
): boolean {
  prune(now);
  let s = State.sessions.find((x) => x.id === id);
  if (s) {
    s.agent = agent;
    s.project = project;
    if (cwd) s.cwd = cwd;
    s.updatedAt = now;
  } else {
    s = { id, agent, project, cwd, state: "idle", steps: [], updatedAt: now, unseen: false };
    State.sessions.push(s);
  }
  const current = State.sessions.find((x) => x.id === State.focusedSession);
  if (!current) {
    focusSession(id);
    return true;
  }
  if (current.id === id) return true;
  const starting = ["SessionStart", "UserPromptSubmit", "PreToolUse"].includes(event);
  const quiet = QUIET.includes(current.state) && now - current.updatedAt > 3000;
  if (starting && quiet && !State.pendingApproval) {
    focusSession(id);
    return true;
  }
  return false;
}

/** Events from a session that isn't on the card: keep its record, flag what matters. */
export function updateBackground(id: string, event: string, payload: Record<string, unknown>) {
  const s = State.sessions.find((x) => x.id === id);
  if (!s) return;
  const step = (text: string) => {
    s.steps.push(text);
    if (s.steps.length > 20) s.steps.shift();
  };
  switch (event) {
    case "UserPromptSubmit":
      s.state = "thinking";
      if (typeof payload.prompt === "string" && payload.prompt) step(payload.prompt.slice(0, 60));
      break;
    case "PreToolUse":
      s.state = "working";
      step(stepLabel(String(payload.tool_name ?? "Tool"), (payload.tool_input as Record<string, unknown>) ?? {}));
      break;
    case "PostToolUse":
    case "PostToolUseFailure":
      s.state = "working";
      break;
    case "Stop":
      s.state = "finished";
      s.unseen = true;
      step((stopMessage(payload) ?? "Done").slice(0, 60));
      Sound.play("finish");
      State.setPillBadge(CLAUDE_ID, "finished");
      break;
    case "StopFailure":
      s.state = "error";
      s.unseen = true;
      Sound.play("error");
      State.setPillBadge(CLAUDE_ID, "error");
      break;
    case "Notification": {
      const m = typeof payload.message === "string" ? payload.message : "";
      if (m.endsWith("?")) {
        s.state = "question";
        s.unseen = true;
        step(m);
      }
      break;
    }
    case "SessionEnd":
      endSession(id);
      break;
  }
  State.notify();
}

/** A session closed: forget it; if it was on the card, show another live one. */
export function endSession(id: string) {
  State.sessions = State.sessions.filter((s) => s.id !== id);
  forget(id);
  if (State.focusedSession !== id) return;
  State.focusedSession = null;
  const next = [...State.sessions].sort((a, b) => b.updatedAt - a.updatedAt)[0];
  if (next) focusSession(next.id);
}

/** Marks a waiting approval on a background session's chip. */
export function flagApproval(id: string) {
  const s = State.sessions.find((x) => x.id === id);
  if (!s) return;
  s.state = "approval";
  s.unseen = true;
}

export function focused(): ClaudeSession | null {
  return State.sessions.find((s) => s.id === State.focusedSession) ?? null;
}
