// What a session did, in order (#22 on macOS): prompts, tool calls, approvals
// (and who gave them), the end of each turn. Kept in memory for the session's
// lifetime; "Copy as Markdown" turns it into something to paste in a PR or issue.

import { stepLabel, stopMessage } from "./labels.ts";

export type TimelineKind = "start" | "prompt" | "tool" | "failed" | "approval" | "auto" | "stop" | "error" | "end";

export interface TimelineEntry {
  at: number;
  kind: TimelineKind;
  text: string;
}

const MAX_PER_SESSION = 300;
const store = new Map<string, TimelineEntry[]>();

function push(sessionId: string, kind: TimelineKind, text: string, at = Date.now()) {
  if (!sessionId) return;
  const list = store.get(sessionId) ?? [];
  list.push({ at, kind, text });
  if (list.length > MAX_PER_SESSION) list.splice(0, list.length - MAX_PER_SESSION);
  store.set(sessionId, list);
}

export function recordEvent(name: string, sessionId: string, payload: Record<string, unknown>, at = Date.now()) {
  const tool = typeof payload.tool_name === "string" ? payload.tool_name : "Tool";
  const input = (payload.tool_input as Record<string, unknown>) ?? {};
  switch (name) {
    case "SessionStart": push(sessionId, "start", "Session started", at); break;
    case "UserPromptSubmit": {
      const p = typeof payload.prompt === "string" ? payload.prompt : "";
      if (p) push(sessionId, "prompt", p.slice(0, 300), at);
      break;
    }
    case "PreToolUse": push(sessionId, "tool", stepLabel(tool, input), at); break;
    case "PostToolUseFailure": push(sessionId, "failed", `${stepLabel(tool, input)} failed`, at); break;
    case "Stop": push(sessionId, "stop", (stopMessage(payload) ?? "Done").slice(0, 300), at); break;
    case "StopFailure": push(sessionId, "error", "The turn failed", at); break;
    case "SessionEnd": push(sessionId, "end", "Session ended", at); break;
  }
}

export function recordApproval(sessionId: string, command: string, decision: "allow" | "deny" | "timeout", at = Date.now()) {
  const verb = decision === "allow" ? "Allowed" : decision === "deny" ? "Denied" : "Left to the terminal";
  push(sessionId, "approval", `${verb} from Coucou: ${command}`, at);
}

export function recordAutoApproval(sessionId: string, command: string, reason: string, at = Date.now()) {
  push(sessionId, "auto", `Auto-approved (${reason}): ${command}`, at);
}

export function entries(sessionId: string): TimelineEntry[] {
  return store.get(sessionId) ?? [];
}

export function forget(sessionId: string) {
  store.delete(sessionId);
}

export function clock(at: number): string {
  const d = new Date(at);
  const two = (n: number) => String(n).padStart(2, "0");
  return `${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`;
}

const ICON: Record<TimelineKind, string> = {
  start: "▶", prompt: "💬", tool: "·", failed: "⚠", approval: "✋", auto: "⚡", stop: "✓", error: "✗", end: "■",
};

export function icon(kind: TimelineKind): string {
  return ICON[kind];
}

/** The session as Markdown: a title, then one line per entry. */
export function markdown(sessionId: string, project: string): string {
  const list = entries(sessionId);
  const lines = [`## ${project} — session timeline`, ""];
  for (const e of list) {
    const text = e.kind === "prompt" ? `**${e.text.replace(/\n+/g, " ")}**` : e.text.replace(/\n+/g, " ");
    lines.push(`- \`${clock(e.at)}\` ${ICON[e.kind]} ${text}`);
  }
  if (!list.length) lines.push("_Nothing recorded yet._");
  return lines.join("\n") + "\n";
}

/** Approvals and auto-approvals in the session: "3 approvals, 1 auto". */
export function summary(sessionId: string): string {
  const list = entries(sessionId);
  const manual = list.filter((e) => e.kind === "approval").length;
  const auto = list.filter((e) => e.kind === "auto").length;
  const tools = list.filter((e) => e.kind === "tool").length;
  const parts = [`${tools} tool call${tools === 1 ? "" : "s"}`];
  if (manual) parts.push(`${manual} approval${manual === 1 ? "" : "s"}`);
  if (auto) parts.push(`${auto} auto`);
  return parts.join(" · ");
}
