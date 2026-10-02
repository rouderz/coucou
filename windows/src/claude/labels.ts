// What a tool call reads like on the island: "Run · npm test", "Edit · app.ts".
// Same labels as the macOS app (HookServer.frenchStep, now in English there too).

import { parsePatch, patchText } from "./codex.ts";

const TOOL_LABELS: Record<string, string> = {
  Bash: "Run",
  PowerShell: "Run",
  shell: "Run",
  Read: "Read",
  Write: "Write",
  Edit: "Edit",
  MultiEdit: "Edit",
  apply_patch: "Edit",
  Glob: "Find",
  Grep: "Search",
  WebSearch: "Web search",
  WebFetch: "Fetch",
  TodoWrite: "Plan",
  Task: "Agent",
  LS: "List",
  NotebookEdit: "Notebook",
};

export function lastPathComponent(p: string): string {
  const cleaned = p.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned;
}

export function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const patch = patchText(input);
  if (patch) {
    const names = parsePatch(patch).map((c) => lastPathComponent(c.path));
    return names.length ? `${label} · ${names.join(", ")}` : label;
  }
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : null);
  const cmd = str("command") ?? (Array.isArray(input.command) ? (input.command as unknown[]).join(" ") : null);
  if (cmd) return `${label} · ${cmd.slice(0, 40)}`;
  const path = str("path") ?? str("file_path");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const query = str("query");
  if (query) return `${label} · ${query.slice(0, 40)}`;
  return label;
}

/**
 * What the Allow button actually authorises: the command, the file, the URL —
 * not just the tool's name. A Codex patch reads as the files it edits.
 */
const APPROVAL_FIELDS = ["command", "file_path", "path", "url", "query", "pattern", "prompt", "description"] as const;

export function approvalTarget(tool: string, input: Record<string, unknown>): string {
  const patch = patchText(input);
  if (patch) {
    const files = parsePatch(patch).map((c) => c.path);
    if (files.length) return `Edit ${files.join(", ")}`;
  }
  for (const field of APPROVAL_FIELDS) {
    const value = input[field];
    if (typeof value === "string" && value.trim()) return `${tool} · ${value.trim()}`;
    if (field === "command" && Array.isArray(value)) return `${tool} · ${value.join(" ")}`;
  }
  return tool;
}

/** Claude Code says `message` at the end of a turn; Codex says `last_assistant_message`. */
export function stopMessage(payload: Record<string, unknown>): string | null {
  for (const key of ["message", "last_assistant_message"]) {
    const v = payload[key];
    if (typeof v === "string" && v.trim()) return v;
  }
  return null;
}
