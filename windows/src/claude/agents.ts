// Cursor CLI and Gemini CLI (#109): each agent's hook events mapped to Coucou's
// (the Claude Code–style events the island already understands), Coucou's answer
// mapped back to each agent's format, and the merge of Coucou's hooks into
// ~/.cursor/hooks.json and ~/.gemini/settings.json. Pure functions, no I/O: the
// relay and the installers call them.
//
// Sources (docs only, nothing recorded from a real run yet):
//  - Gemini: google-gemini/gemini-cli docs/hooks/reference.md and docs/reference/tools.md
//  - Cursor: cursor.com/docs/hooks, as quoted by search results (the site itself
//    was not reachable when this was written), plus public hook examples.
// Grok CLI is left out: its format is not documented well enough to map.

export type Agent = "cursor" | "gemini";
export type Json = Record<string, unknown>;

/** What the island gets: Claude Code's vocabulary plus the agent tag. */
export interface CoucouEvent extends Json {
  agent: Agent;
  hook_event_name: string;
  session_id: string;
  cwd: string;
}

export interface Mapped {
  event: CoucouEvent;
  /** The agent waits for an answer to this event (an approval). */
  waits: boolean;
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const obj = (v: unknown): Json | undefined =>
  v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : undefined;

function parseObject(v: unknown): Json {
  if (obj(v)) return v as Json;
  if (typeof v === "string") {
    try {
      return obj(JSON.parse(v)) ?? {};
    } catch {
      return {};
    }
  }
  return {};
}

// ---------------------------------------------------------------- Cursor

/** Cursor hook events Coucou installs, in the order they are written. */
export const CURSOR_EVENTS = [
  "sessionStart",
  "sessionEnd",
  "beforeSubmitPrompt",
  "beforeShellExecution",
  "beforeMCPExecution",
  "afterFileEdit",
  "postToolUse",
  "stop",
] as const;

/**
 * preToolUse is mapped but not installed: for a shell command it fires next to
 * beforeShellExecution, and answering both would ask twice.
 */
export function mapCursor(p: Json): Mapped | null {
  const name = str(p.hook_event_name);
  if (!name) return null;
  const session_id = str(p.conversation_id) ?? str(p.session_id);
  if (!session_id) return null;
  const roots = Array.isArray(p.workspace_roots) ? p.workspace_roots : [];
  const cwd = str(p.cwd) ?? str(roots[0]) ?? "";
  const base = { agent: "cursor" as const, session_id, cwd };
  const done = (hook_event_name: string, extra: Json = {}, waits = false): Mapped => ({
    event: { ...base, hook_event_name, ...extra },
    waits,
  });
  switch (name) {
    case "sessionStart":
      return done("SessionStart");
    case "sessionEnd":
      return done("SessionEnd");
    case "beforeSubmitPrompt":
      return done("UserPromptSubmit");
    case "beforeShellExecution": {
      const command = str(p.command);
      if (!command) return null;
      return done("PermissionRequest", { tool_name: "Bash", tool_input: { command } }, true);
    }
    case "beforeMCPExecution": {
      const tool = str(p.tool_name);
      if (!tool) return null;
      const server = str(p.mcp_server_name);
      return done(
        "PermissionRequest",
        { tool_name: server ? `mcp__${server}__${tool}` : tool, tool_input: parseObject(p.tool_input) },
        true,
      );
    }
    case "afterFileEdit": {
      const file_path = str(p.file_path);
      return done("PostToolUse", { tool_name: "Edit", tool_input: file_path ? { file_path } : {} });
    }
    case "preToolUse":
      return done("PreToolUse", { tool_name: str(p.tool_name) ?? "Tool", tool_input: parseObject(p.tool_input) });
    case "postToolUse":
      return done("PostToolUse", { tool_name: str(p.tool_name) ?? "Tool", tool_input: parseObject(p.tool_input) });
    case "stop":
      // status is "completed" | "aborted" | "error"
      return done(p.status === "error" ? "StopFailure" : "Stop");
    default:
      return null;
  }
}

// ---------------------------------------------------------------- Gemini

export const GEMINI_EVENTS = [
  "SessionStart",
  "SessionEnd",
  "BeforeAgent",
  "AfterAgent",
  "BeforeTool",
  "AfterTool",
  "Notification",
] as const;

/** Gemini's built-in tool names (docs/reference/tools.md) in Claude Code's. */
const GEMINI_TOOLS: Record<string, string> = {
  run_shell_command: "Bash",
  write_file: "Write",
  replace: "Edit",
  read_file: "Read",
  glob: "Glob",
  grep_search: "Grep",
  web_fetch: "WebFetch",
  google_web_search: "WebSearch",
};

export function mapGemini(p: Json): Mapped | null {
  const name = str(p.hook_event_name);
  const session_id = str(p.session_id);
  if (!name || !session_id) return null;
  const base = { agent: "gemini" as const, session_id, cwd: str(p.cwd) ?? "" };
  const done = (hook_event_name: string, extra: Json = {}, waits = false): Mapped => ({
    event: { ...base, hook_event_name, ...extra },
    waits,
  });
  const tool = () => {
    const raw = str(p.tool_name) ?? "Tool";
    return { tool_name: GEMINI_TOOLS[raw] ?? raw, tool_input: { ...parseObject(p.tool_input) } };
  };
  switch (name) {
    case "SessionStart":
      return done("SessionStart");
    case "SessionEnd":
      return done("SessionEnd");
    case "BeforeAgent":
      return done("UserPromptSubmit", str(p.prompt) ? { prompt: p.prompt } : {});
    case "AfterAgent":
      return done("Stop", str(p.prompt_response) ? { last_assistant_message: p.prompt_response } : {});
    case "BeforeTool":
      return done("PermissionRequest", tool(), true);
    case "AfterTool":
      return done("PostToolUse", tool());
    case "Notification":
      return done("Notification", str(p.message) ? { message: p.message } : {});
    default:
      return null;
  }
}

export function mapEvent(agent: Agent, payload: Json): Mapped | null {
  return agent === "cursor" ? mapCursor(payload) : mapGemini(payload);
}

// ---------------------------------------------------------------- answers

/** What the island answers: allow, always (allow + remember), deny, or ask. */
export type Answer = "allow" | "always" | "deny" | "ask" | string;

export interface AgentReply {
  /** Printed on stdout, if anything. */
  stdout: string | null;
  /** Process exit code; 2 blocks the action and puts stderr in front of the agent. */
  exit: 0 | 2;
  stderr?: string;
}

const DENIED = "Denied from Coucou";
const SILENT: AgentReply = { stdout: null, exit: 0 };

/**
 * Silence is the safe answer: anything unrecognised prints nothing and exits 0,
 * so the agent asks in its own UI exactly as if Coucou were not installed.
 * Never "allow" unless the island said so. `hookEvent` is the agent's own event
 * name (what it sent), not Coucou's.
 */
export function answerFor(agent: Agent, hookEvent: string, answer: Answer): AgentReply {
  const a = answer.trim();
  if (agent === "cursor") {
    if (hookEvent !== "beforeShellExecution" && hookEvent !== "beforeMCPExecution") return SILENT;
    if (a === "allow" || a === "always") return { stdout: JSON.stringify({ permission: "allow" }), exit: 0 };
    if (a === "ask") return { stdout: JSON.stringify({ permission: "ask" }), exit: 0 };
    if (a === "deny") {
      return {
        stdout: JSON.stringify({ permission: "deny", user_message: DENIED, agent_message: DENIED }),
        exit: 0,
      };
    }
    return SILENT;
  }
  if (hookEvent !== "BeforeTool") return SILENT;
  // Gemini has no "ask": staying silent leaves its own confirmation in place.
  if (a === "allow" || a === "always") return { stdout: JSON.stringify({ decision: "allow" }), exit: 0 };
  if (a === "deny") return { stdout: JSON.stringify({ decision: "deny", reason: DENIED }), exit: 0 };
  return SILENT;
}

/** Gemini's other way to refuse: exit 2, the reason on stderr. */
export function geminiDenyByExit(reason = DENIED): AgentReply {
  return { stdout: null, exit: 2, stderr: reason };
}

// ---------------------------------------------------------------- config merge

const MARKERS = ["coucou-hook", "nb-hook"];

function isOurCommand(command: unknown): boolean {
  return typeof command === "string" && MARKERS.some((m) => command.includes(m));
}

const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v));

function hooksOf(root: Json): Json {
  return obj(root.hooks) ? clone(root.hooks as Json) : {};
}

/** The relay command for an agent, e.g. `"/x/coucou-hook" --agent cursor`. */
export function relayCommand(exePath: string, agent: Agent): string {
  return `"${exePath.replace(/\\/g, "/")}" --agent ${agent}`;
}

// Cursor: { version: 1, hooks: { event: [{ command }] } }

function cursorEntryIsOurs(e: unknown): boolean {
  return isOurCommand(obj(e)?.command);
}

export function cursorInstalled(root: Json, command: string): Json {
  const out: Json = { ...clone(root) };
  if (out.version === undefined) out.version = 1;
  const hooks = hooksOf(out);
  for (const event of CURSOR_EVENTS) {
    const list = Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : [];
    hooks[event] = [...list.filter((e) => !cursorEntryIsOurs(e)), { command }];
  }
  out.hooks = hooks;
  return out;
}

export function cursorUninstalled(root: Json): Json {
  const out: Json = { ...clone(root) };
  if (!obj(out.hooks)) return out;
  const kept: Json = {};
  for (const [event, value] of Object.entries(out.hooks as Json)) {
    if (!Array.isArray(value)) {
      kept[event] = value;
      continue;
    }
    const rest = value.filter((e) => !cursorEntryIsOurs(e));
    if (rest.length) kept[event] = rest;
  }
  if (Object.keys(kept).length) out.hooks = kept;
  else delete out.hooks;
  return out;
}

export function cursorHasOurs(root: Json): boolean {
  const hooks = obj(root.hooks);
  return !!hooks && Object.values(hooks).some((l) => Array.isArray(l) && l.some(cursorEntryIsOurs));
}

// Gemini: { hooks: { Event: [{ matcher?, hooks: [{ type, command, name, timeout (ms) }] }] } }

const GEMINI_TIMEOUT_MS: Record<string, number> = { BeforeTool: 120_000 };
const GEMINI_DEFAULT_TIMEOUT_MS = 10_000;

function geminiGroupIsOurs(g: unknown): boolean {
  const inner = obj(g)?.hooks;
  return Array.isArray(inner) && inner.some((h) => isOurCommand(obj(h)?.command));
}

export function geminiInstalled(root: Json, command: string): Json {
  const out: Json = { ...clone(root) };
  const hooks = hooksOf(out);
  for (const event of GEMINI_EVENTS) {
    const list = Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : [];
    hooks[event] = [
      ...list.filter((g) => !geminiGroupIsOurs(g)),
      {
        hooks: [
          {
            type: "command",
            command,
            name: "coucou",
            timeout: GEMINI_TIMEOUT_MS[event] ?? GEMINI_DEFAULT_TIMEOUT_MS,
          },
        ],
      },
    ];
  }
  out.hooks = hooks;
  return out;
}

export function geminiUninstalled(root: Json): Json {
  const out: Json = { ...clone(root) };
  if (!obj(out.hooks)) return out;
  const kept: Json = {};
  for (const [event, value] of Object.entries(out.hooks as Json)) {
    if (!Array.isArray(value)) {
      kept[event] = value;
      continue;
    }
    const rest = value.filter((g) => !geminiGroupIsOurs(g));
    if (rest.length) kept[event] = rest;
  }
  if (Object.keys(kept).length) out.hooks = kept;
  else delete out.hooks;
  return out;
}

export function geminiHasOurs(root: Json): boolean {
  const hooks = obj(root.hooks);
  return !!hooks && Object.values(hooks).some((l) => Array.isArray(l) && l.some(geminiGroupIsOurs));
}

// ---------------------------------------------------------------- file level

export type Plan =
  | { ok: true; after: string; changed: boolean; diff: string }
  | { ok: false; error: string };

/**
 * Turns the current file text into what Settings shows before anything is
 * written: the new text and a diff. Invalid JSON is an error, never an empty
 * file to overwrite. The caller writes only after the user confirms, and only
 * after copying the file to `backupName(...)`.
 */
export function planChange(agent: Agent, current: string | null, command: string, install: boolean): Plan {
  let text = current ?? "";
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  let root: Json = {};
  if (text.trim() !== "") {
    try {
      const parsed = JSON.parse(text);
      if (!obj(parsed)) return { ok: false, error: "The file isn't a JSON object, so Coucou won't touch it." };
      root = parsed as Json;
    } catch (e) {
      return { ok: false, error: `The file isn't valid JSON (${(e as Error).message}), so Coucou won't touch it.` };
    }
  }
  const next =
    agent === "cursor"
      ? install ? cursorInstalled(root, command) : cursorUninstalled(root)
      : install ? geminiInstalled(root, command) : geminiUninstalled(root);
  const after = JSON.stringify(next, null, 2) + "\n";
  const before = text.trim() === "" ? "" : JSON.stringify(root, null, 2) + "\n";
  // Removing what isn't there changes nothing (and never creates a file).
  const ours = agent === "cursor" ? cursorHasOurs(root) : geminiHasOurs(root);
  if (!install && !ours) return { ok: true, after: before, changed: false, diff: "" };
  return { ok: true, after, changed: before !== after, diff: unifiedDiff(before, after) };
}

/** `hooks.json.bak-20261003-140501` next to the file (UTC). */
export function backupName(file: string, now: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  const stamp =
    `${now.getUTCFullYear()}${p(now.getUTCMonth() + 1)}${p(now.getUTCDate())}-` +
    `${p(now.getUTCHours())}${p(now.getUTCMinutes())}${p(now.getUTCSeconds())}`;
  return `${file}.bak-${stamp}`;
}

/** Line diff (LCS): `+`, `-` and unchanged lines, two lines of context, `...` for the rest. */
export function unifiedDiff(before: string, after: string): string {
  const a = before === "" ? [] : before.replace(/\n$/, "").split("\n");
  const b = after === "" ? [] : after.replace(/\n$/, "").split("\n");
  const n = a.length, m = b.length;
  const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const ops: { t: " " | "+" | "-"; s: string }[] = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { ops.push({ t: " ", s: a[i] }); i++; j++; }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) ops.push({ t: "-", s: a[i++] });
    else ops.push({ t: "+", s: b[j++] });
  }
  while (i < n) ops.push({ t: "-", s: a[i++] });
  while (j < m) ops.push({ t: "+", s: b[j++] });
  if (!ops.some((o) => o.t !== " ")) return "";
  const CONTEXT = 2;
  const near = (k: number) => ops.slice(Math.max(0, k - CONTEXT), k + CONTEXT + 1).some((x) => x.t !== " ");
  const lines: string[] = [];
  let skipped = false;
  ops.forEach((o, k) => {
    if (near(k)) { lines.push(o.t + o.s); skipped = false; }
    else if (!skipped) { lines.push("..."); skipped = true; }
  });
  return lines.join("\n");
}
