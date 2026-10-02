// Claude Code / Codex hook events → island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app:
// several sessions (one on the card), approvals with their risk, a queue when
// two ask at once, auto-approval per project, and a timeline of each session.
// Difference from macOS: no terminal filter — every terminal's sessions count.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ApprovalInfo } from "../core/state";
import type { Island } from "./island";
import { classify } from "../claude/risk.ts";
import { shouldAutoAllow } from "../claude/autoApprove.ts";
import { approvalTarget, lastPathComponent, stepLabel, stopMessage } from "../claude/labels.ts";
import { recordApproval, recordAutoApproval, recordEvent } from "../claude/timeline.ts";
import { buildPreview } from "../claude/preview.ts";
import {
  CLAUDE_ID, flagApproval, focusSession, routeSession, syncFocused, updateBackground, endSession,
} from "../claude/sessions.ts";

/** The relay gives up after 110 s; the card must be gone by then. */
const DECISION_MS = 105_000;

/** Clears the approval card if no decision was made before the hook gave up. */
let pendingTimeout: number | null = null;
const queueTimers = new Map<string, number>();

interface HookPayload {
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  message?: string;
  last_assistant_message?: string;
  /** UserPromptSubmit carries `prompt`; `message` belongs to Notification/Stop. */
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  /** "codex" when the relay was installed for Codex CLI. */
  agent?: string;
}

const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy",
  notchbuddy: "Notch Buddy",
  notch_buddy: "Notch Buddy",
};

function aliasProjectName(name: string): string {
  return PROJECT_ALIASES[name.toLowerCase()] ?? name;
}

function upsert(projectName: string, cwd: string) {
  const t = State.tasks.find((x) => x.id === CLAUDE_ID);
  if (!t) return;
  t.name = projectName;
  if (cwd) t.sessionCwd = cwd;
}

function clearSession() {
  const t = State.tasks.find((x) => x.id === CLAUDE_ID);
  if (!t) return;
  t.steps = [];
  t.stepIndex = 0;
  t.name = "VS Code";
  t.pillBadge = null;
}

let islandRef: Island | null = null;

export function registerHookHandlers(island: Island) {
  islandRef = island;
  void onEvent<HookPayload>("hook", (payload) => handleHook(island, payload));
}

function handleHook(island: Island, payload: HookPayload) {
  if (State.paused) {
    // Silence here used to cost Claude Code nearly two minutes: the relay waited
    // for a decision from an island that had already decided not to look. Say so,
    // and the terminal takes the question immediately.
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }

  const name = payload.hook_event_name ?? "";
  const cwd = payload.cwd ?? "";
  const projectName = aliasProjectName(lastPathComponent(cwd) || "Session");
  const agent = payload.agent ?? "claude";
  const sessionId = payload.session_id ?? "";
  const raw = payload as unknown as Record<string, unknown>;

  if (name === "StatusLine") {
    planUsage(raw);
    return;
  }

  if (name === "PermissionRequest") {
    permissionRequest(island, payload, projectName, agent);
    State.notify();
    return;
  }

  recordEvent(name, sessionId, raw);

  // Several sessions: only the focused one drives the card.
  if (sessionId && !routeSession(sessionId, agent, projectName, cwd, name)) {
    updateBackground(sessionId, name, raw);
    return;
  }

  const focused = State.focusId === CLAUDE_ID;

  /** Alerts force the island open; work events only reveal the compact island. */
  const surface = (view: Parameters<Island["alert"]>[0], isAlert: boolean) => {
    if (State.mode === "expanded") {
      if (isAlert) island.setView(view);
    } else if (isAlert) {
      island.alert(view);
    } else if (State.mode === "hidden") {
      island.reveal();
    }
  };

  switch (name) {
    case "SessionStart":
      upsert(projectName, cwd);
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      upsert(projectName, cwd);
      State.updateTask(CLAUDE_ID, "thinking");
      const asked = payload.prompt ?? payload.message;
      if (asked) State.appendStep(CLAUDE_ID, asked.slice(0, 60));
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      upsert(projectName, cwd);
      State.updateTask(CLAUDE_ID, "working");
      State.appendStep(CLAUDE_ID, stepLabel(payload.tool_name ?? "Tool", payload.tool_input ?? {}));
      surface("overview", false);
      break;
    }

    case "PostToolUse":
      State.updateTask(CLAUDE_ID, "working");
      break;

    case "PostToolUseFailure":
      State.updateTask(CLAUDE_ID, "working");
      State.appendStep(CLAUDE_ID, "⚠ failed");
      break;

    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        State.updateTask(CLAUDE_ID, "ratelimit");
        Sound.play("rate");
      } else if (message.endsWith("?")) {
        State.updateTask(CLAUDE_ID, "question");
        State.appendStep(CLAUDE_ID, message);
      }
      break;
    }

    case "Stop": {
      State.updateTask(CLAUDE_ID, "finished");
      const said = stopMessage(raw);
      State.appendStep(CLAUDE_ID, (said ?? "Done").slice(0, 60));
      Sound.play("finish");
      if (focused) surface("finished", true);
      else State.setPillBadge(CLAUDE_ID, "finished");
      window.setTimeout(() => {
        State.updateTask(CLAUDE_ID, "idle");
        State.setPillBadge(CLAUDE_ID, null);
        syncFocused();
      }, 5200);
      break;
    }

    case "StopFailure":
      State.updateTask(CLAUDE_ID, "error");
      Sound.play("error");
      if (focused) surface("error", true);
      else State.setPillBadge(CLAUDE_ID, "error");
      break;

    case "SessionEnd":
      State.updateTask(CLAUDE_ID, "idle");
      clearSession();
      if (sessionId) endSession(sessionId);
      break;

    case "SubagentStart":
      State.appendStep(CLAUDE_ID, "+ subagent");
      break;

    case "SubagentStop":
      State.appendStep(CLAUDE_ID, "• subagent done");
      break;

    default:
      break;
  }
  syncFocused();
  State.notify();
}

// ── Plan usage (Claude Code's status line) ─────────────────────────────────

function planUsage(payload: Record<string, unknown>) {
  const now = Date.now();
  const window = (v: unknown) => {
    const w = v as { used_percentage?: number; resets_at?: number } | undefined;
    if (typeof w?.used_percentage !== "number") return null;
    const resetsAt = typeof w.resets_at === "number" ? w.resets_at * 1000 : 0;
    return resetsAt && resetsAt < now ? null : { percent: w.used_percentage, resetsAt };
  };
  const limits = (payload.rate_limits ?? {}) as Record<string, unknown>;
  const prev = State.planUsage;
  const ctx = (payload.context_window as { used_percentage?: number } | undefined)?.used_percentage;
  State.planUsage = {
    // Limits come after the session's first reply: keep the last known ones meanwhile.
    fiveHour: window(limits.five_hour) ?? (prev?.fiveHour && prev.fiveHour.resetsAt > now ? prev.fiveHour : null),
    sevenDay: window(limits.seven_day) ?? (prev?.sevenDay && prev.sevenDay.resetsAt > now ? prev.sevenDay : null),
    context: typeof ctx === "number" ? ctx : prev?.context ?? null,
    model: (payload.model as { display_name?: string } | undefined)?.display_name ?? prev?.model ?? null,
  };
  State.notify();
}

// ── Permission requests ─────────────────────────────────────────────────────

function permissionRequest(island: Island, payload: HookPayload, project: string, agent: string) {
  const requestId = payload.request_id ?? "";
  const sessionId = payload.session_id ?? "";
  const cwd = payload.cwd ?? "";
  const tool = payload.tool_name ?? "Tool";
  const input = payload.tool_input ?? {};
  const verdict = classify(tool, input, cwd);
  const approval: ApprovalInfo = {
    requestId, sessionId, tool,
    command: approvalTarget(tool, input),
    risk: verdict.risk, riskReason: verdict.reason,
    cwd, project, agent,
    preview: buildPreview(tool, input, cwd),
  };

  // Auto-approval for this project (#29 on macOS): answered at once, no card,
  // written to the timeline so it never happens silently.
  if (requestId && shouldAutoAllow(State.settings.autoApprove ?? {}, cwd, verdict.risk)) {
    void Bridge.approvalDecision(requestId, "allow");
    recordAutoApproval(sessionId, approval.command, `${verdict.risk} risk · ${verdict.reason}`);
    return;
  }

  // Another request is on screen: wait in line instead of being turned away.
  // The ack tells the relay a human will look, so it keeps waiting.
  if (State.pendingApproval && State.pendingApproval.requestId !== requestId) {
    if (requestId) void Bridge.approvalAck(requestId);
    State.approvalQueue.push(approval);
    if (sessionId) {
      routeSession(sessionId, agent, project, cwd, "PermissionRequest");
      flagApproval(sessionId);
    }
    State.setPillBadge(CLAUDE_ID, "approval");
    queueTimers.set(requestId, window.setTimeout(() => {
      // Too late to show it: the terminal asks instead.
      queueTimers.delete(requestId);
      State.approvalQueue = State.approvalQueue.filter((a) => a.requestId !== requestId);
      void Bridge.approvalDecline(requestId);
      recordApproval(sessionId, approval.command, "timeout");
      State.notify();
    }, DECISION_MS));
    return;
  }

  show(island, approval);
}

function show(island: Island, approval: ApprovalInfo) {
  const { requestId, sessionId } = approval;
  if (sessionId) {
    routeSession(sessionId, approval.agent, approval.project, approval.cwd, "PermissionRequest");
    if (State.focusedSession !== sessionId) focusSession(sessionId);
  }
  upsert(approval.project, approval.cwd);
  if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
  State.pendingApproval = approval;
  // The relay's short ack window closes in 800 ms; everything below this
  // line is synchronous, so the card really is up by the time it lands.
  if (requestId) void Bridge.approvalAck(requestId);
  State.updateTask(CLAUDE_ID, "approval");
  State.isPinned = true;
  Sound.play("approval");
  if (State.focusId === CLAUDE_ID) {
    island.alert(approval.preview ? "review" : "approval");
  } else {
    State.setPillBadge(CLAUDE_ID, "approval");
    island.reveal();
  }
  // Coucou answers within 108 s or not at all; after that the terminal has
  // taken over and the card would be lying.
  pendingTimeout = window.setTimeout(() => {
    pendingTimeout = null;
    if (State.pendingApproval?.requestId !== requestId) return;
    recordApproval(sessionId, approval.command, "timeout");
    State.pendingApproval = null;
    State.isPinned = false;
    island.dropPin();
    State.updateTask(CLAUDE_ID, "working");
    State.setPillBadge(CLAUDE_ID, null);
    if (State.view === "approval" || State.view === "review") island.setView(State.defaultView());
    showNextApproval();
    State.notify();
  }, DECISION_MS);
}

/** After a click on Allow / Deny: log it, then show whoever is waiting. */
export function approvalDecided(approval: ApprovalInfo, decision: "allow" | "deny") {
  recordApproval(approval.sessionId, approval.command, decision);
  if (pendingTimeout != null) {
    window.clearTimeout(pendingTimeout);
    pendingTimeout = null;
  }
  syncFocused();
  showNextApproval();
}

function showNextApproval() {
  if (State.pendingApproval || !islandRef) return;
  const next = State.approvalQueue.shift();
  if (!next) return;
  const timer = queueTimers.get(next.requestId);
  if (timer != null) window.clearTimeout(timer);
  queueTimers.delete(next.requestId);
  show(islandRef, next);
}
