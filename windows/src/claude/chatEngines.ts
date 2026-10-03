// Chat engines that run another agent CLI the user already signed in to (#108).
// Pure logic only (no process is started here): the table of how each CLI is called,
// where to look for it, how to read its output and how to word its failures.
// Mirrored by NotchBuddy/Sources/App/ChatEngineCLIs.swift; keep both in step.
//
// What is CONFIRMED comes from the CLIs' own open-source repositories and docs (cited per
// engine below). Cursor CLI and Grok CLI are in the table but NOT confirmed: their docs
// (cursor.com/docs/cli, docs.x.ai/build/cli) could not be read while writing this, so no
// flags are listed for them and they have no parser. Add them once someone has checked
// `--help` and a real output sample.

export type EngineID = "codex" | "gemini" | "cursor" | "grok";

export interface EngineInfo {
  id: EngineID;
  name: string;
  /** Executable name looked up on PATH (from the issue; for cursor and grok not yet verified). */
  binary: string;
  /** Flags and output format checked against the CLI's source or docs. */
  confirmed: boolean;
  /** Where the facts below come from. */
  source: string;
  /** Command that signs the user in, when known. */
  loginCommand: string | null;
}

export const ENGINES: readonly EngineInfo[] = [
  {
    id: "codex",
    name: "Codex",
    binary: "codex",
    confirmed: true,
    // `codex exec [OPTIONS] [PROMPT]`; `--json` prints events as JSONL on stdout; `--skip-git-repo-check`,
    // `--ephemeral`, `-m/--model`, `-s/--sandbox read-only|workspace-write|danger-full-access`.
    //   https://github.com/openai/codex/blob/main/codex-rs/exec/src/cli.rs
    //   https://github.com/openai/codex/blob/main/codex-rs/utils/cli/src/shared_options.rs
    //   https://github.com/openai/codex/blob/main/codex-rs/utils/cli/src/sandbox_mode_cli_arg.rs
    // Events (thread.started, turn.started, item.started/updated/completed, turn.completed with usage,
    // turn.failed, error):
    //   https://github.com/openai/codex/blob/main/codex-rs/exec/src/exec_events.rs
    // Sign-in check: `codex login status` writes "Logged in using ChatGPT" (or "... an API key - ...")
    // to STDERR and exits 0; "Not logged in" and exit 1 otherwise:
    //   https://github.com/openai/codex/blob/main/codex-rs/cli/src/login.rs (run_login_status)
    // Docs page (not reachable from the build sandbox): https://developers.openai.com/codex/noninteractive
    source: "github.com/openai/codex (codex-rs/exec, codex-rs/cli)",
    loginCommand: "codex login",
  },
  {
    id: "gemini",
    name: "Gemini",
    binary: "gemini",
    confirmed: true,
    // `-p/--prompt` forces non-interactive mode; `-o/--output-format text|json|stream-json`; `-m/--model`;
    // `--approval-mode default|auto_edit|yolo|plan`:
    //   https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/cli-reference.md
    // Headless output (json: {response, stats, error?}; stream-json: init, message, tool_use, tool_result,
    // error, result) and exit codes (0, 1, 42 input, 53 turn limit):
    //   https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/headless.md
    //   https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/output/types.ts
    // Exit code 41 = FatalAuthenticationError:
    //   https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/errors.ts
    // There is no documented "am I signed in" command: sign-in is detected from the exit code 41.
    source: "github.com/google-gemini/gemini-cli (docs/cli, packages/core)",
    loginCommand: null,
  },
  { id: "cursor", name: "Cursor", binary: "cursor-agent", confirmed: false, source: "unconfirmed", loginCommand: null },
  { id: "grok", name: "Grok", binary: "grok", confirmed: false, source: "unconfirmed", loginCommand: null },
];

export function engineInfo(id: EngineID): EngineInfo {
  return ENGINES.find((e) => e.id === id)!;
}

/** Engines Coucou can run today (the ones with a confirmed call and parser). */
export function runnableEngines(): EngineInfo[] {
  return ENGINES.filter((e) => e.confirmed);
}

// MARK: - Invocation

export interface RunOptions {
  model?: string;
}

/**
 * Arguments for one non-interactive turn, or null when the call isn't confirmed.
 * Chats never edit files: Codex runs in its read-only sandbox. For Gemini nothing
 * confirmed makes headless runs read-only, so its edit-capable approval modes are never
 * requested and the default is kept; the runner must still start it in an empty temporary folder.
 */
export function invocation(id: EngineID, prompt: string, opts: RunOptions = {}): string[] | null {
  const model = opts.model?.trim();
  switch (id) {
    case "codex":
      return ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", ...(model ? ["--model", model] : []), prompt];
    case "gemini":
      return ["--output-format", "stream-json", ...(model ? ["--model", model] : []), "--prompt", prompt];
    default:
      return null;
  }
}

/** Arguments that ask the CLI whether it is signed in, when it has such a command (exit 0 = signed in). */
export function signInCheck(id: EngineID): string[] | null {
  return id === "codex" ? ["login", "status"] : null;
}

/** Environment for the runner: its hooks must never reach the island. */
export const INTERNAL_ENV = { COUCOU_INTERNAL: "1" } as const;

// MARK: - Detection

/** Folders where the CLIs' installers usually put their binary, on top of PATH. */
export function installDirs(home: string, platform: "mac" | "windows" | "linux"): string[] {
  const sep = platform === "windows" ? "\\" : "/";
  const h = (rest: string) => `${home}${sep}${rest.split("/").join(sep)}`;
  const common = [h(".local/bin"), h(".npm-global/bin"), h(".bun/bin"), h(".volta/bin")];
  if (platform === "mac") return ["/opt/homebrew/bin", "/usr/local/bin", ...common];
  if (platform === "linux") return ["/usr/local/bin", "/usr/bin", "/home/linuxbrew/.linuxbrew/bin", ...common];
  return [h("AppData/Roaming/npm"), h("scoop/shims"), h(".bun/bin"), h(".volta/bin"), h(".local/bin")];
}

/** Every path to try for a binary: PATH first, then the usual install folders (no duplicates). */
export function candidatePaths(
  binary: string,
  opts: { pathEnv: string; home: string; platform: "mac" | "windows" | "linux" },
): string[] {
  const win = opts.platform === "windows";
  const sep = win ? "\\" : "/";
  const fromPath = opts.pathEnv.split(win ? ";" : ":").filter(Boolean);
  const names = win ? [`${binary}.cmd`, `${binary}.exe`, `${binary}.ps1`] : [binary];
  const out: string[] = [];
  for (const dir of [...fromPath, ...installDirs(opts.home, opts.platform)]) {
    for (const n of names) {
      const p = `${dir.replace(/[\\/]+$/, "")}${sep}${n}`;
      if (!out.includes(p)) out.push(p);
    }
  }
  return out;
}

// MARK: - Output

export type ChatEvent =
  | { kind: "session"; id: string }
  | { kind: "text"; text: string }
  | { kind: "usage"; inputTokens: number; outputTokens: number }
  | { kind: "error"; message: string }
  | { kind: "done" };

function obj(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

function str(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

function parseJSON(line: string): Record<string, unknown> | null {
  const t = line.trim();
  if (!t.startsWith("{")) return null;
  try {
    return obj(JSON.parse(t));
  } catch {
    return null;
  }
}

/**
 * One JSONL line of `codex exec --json` as chat events. Each `agent_message` item arrives complete
 * (no token deltas), so `text` carries a whole message. Other items (commands, reasoning, tools) are ignored.
 */
export function parseCodexLine(line: string): ChatEvent[] {
  const e = parseJSON(line);
  if (!e) return [];
  switch (e.type) {
    case "thread.started": {
      const id = str(e.thread_id);
      return id ? [{ kind: "session", id }] : [];
    }
    case "item.completed": {
      const item = obj(e.item);
      if (item?.type !== "agent_message") return [];
      const text = str(item.text);
      return text ? [{ kind: "text", text }] : [];
    }
    case "turn.completed": {
      const u = obj(e.usage);
      const out: ChatEvent[] = [];
      if (u) out.push({ kind: "usage", inputTokens: num(u.input_tokens), outputTokens: num(u.output_tokens) });
      out.push({ kind: "done" });
      return out;
    }
    case "turn.failed": {
      const msg = str(obj(e.error)?.message);
      return [{ kind: "error", message: msg ?? "Turn failed" }];
    }
    case "error": {
      const msg = str(e.message);
      return msg ? [{ kind: "error", message: msg }] : [];
    }
    default:
      return [];
  }
}

/**
 * One JSONL line of `gemini --output-format stream-json`. Assistant `message` events carry chunks
 * (`delta: true`) of the answer; user echoes, tool events and warnings are ignored.
 */
export function parseGeminiLine(line: string): ChatEvent[] {
  const e = parseJSON(line);
  if (!e) return [];
  switch (e.type) {
    case "init": {
      const id = str(e.session_id);
      return id ? [{ kind: "session", id }] : [];
    }
    case "message": {
      if (e.role !== "assistant") return [];
      const text = str(e.content);
      return text ? [{ kind: "text", text }] : [];
    }
    case "error":
      // severity "warning" is non-fatal; the final `result` says whether the run failed.
      return e.severity === "error" && str(e.message) ? [{ kind: "error", message: str(e.message)! }] : [];
    case "result": {
      if (e.status === "error") {
        return [{ kind: "error", message: str(obj(e.error)?.message) ?? "Gemini failed" }];
      }
      const s = obj(e.stats);
      const out: ChatEvent[] = [];
      if (s) out.push({ kind: "usage", inputTokens: num(s.input_tokens), outputTokens: num(s.output_tokens) });
      out.push({ kind: "done" });
      return out;
    }
    default:
      return [];
  }
}

/** The single object of `gemini --output-format json`: the answer, or its error. */
export function parseGeminiJSON(output: string): ChatEvent[] {
  const e = parseJSON(output);
  if (!e) return [];
  const err = obj(e.error);
  if (err) return [{ kind: "error", message: str(err.message) ?? "Gemini failed" }];
  const out: ChatEvent[] = [];
  const id = str(e.session_id);
  if (id) out.push({ kind: "session", id });
  const text = str(e.response);
  if (text) out.push({ kind: "text", text });
  out.push({ kind: "done" });
  return out;
}

/** Builds the answer as events come in. `onText` should get `text` after each call. */
export class AnswerBuilder {
  private parts: string[] = [];
  sessionID: string | null = null;
  usage: { inputTokens: number; outputTokens: number } | null = null;
  error: string | null = null;
  done = false;

  private readonly engine: EngineID;

  constructor(engine: EngineID) {
    this.engine = engine;
  }

  /** Codex messages are whole paragraphs, Gemini's are chunks to glue together. */
  get text(): string {
    return this.parts.join(this.engine === "gemini" ? "" : "\n\n");
  }

  push(events: ChatEvent[]) {
    for (const ev of events) {
      if (ev.kind === "text") this.parts.push(ev.text);
      else if (ev.kind === "session") this.sessionID = ev.id;
      else if (ev.kind === "usage") this.usage = { inputTokens: ev.inputTokens, outputTokens: ev.outputTokens };
      else if (ev.kind === "error") this.error = ev.message;
      else this.done = true;
    }
  }
}

export function parseLine(id: EngineID, line: string): ChatEvent[] {
  if (id === "codex") return parseCodexLine(line);
  if (id === "gemini") return parseGeminiLine(line);
  return [];
}

// MARK: - Failures

export type FailureKind = "notInstalled" | "notSignedIn" | "rateLimited" | "failed";

export interface Failure {
  kind: FailureKind;
  /** In words the user can act on (English; translated in i18n.ts). */
  message: string;
}

const MESSAGES: Record<"codex" | "gemini", Record<Exclude<FailureKind, "failed">, string>> = {
  codex: {
    notInstalled: "Codex isn't installed. Install it, or pick another chat engine in Settings.",
    notSignedIn: "Codex isn't signed in. Run `codex login` in a terminal, then ask again.",
    rateLimited: "Codex says you hit its usage limit. Wait a bit, or pick another chat engine.",
  },
  gemini: {
    notInstalled: "Gemini CLI isn't installed. Install it, or pick another chat engine in Settings.",
    notSignedIn: "Gemini CLI isn't signed in. Run `gemini` in a terminal and sign in, then ask again.",
    rateLimited: "Gemini says you hit its usage limit. Wait a bit, or pick another chat engine.",
  },
};

// Heuristics, NOT taken from the CLIs' docs: the wording of their rate-limit and sign-in errors is not
// documented, so these look for common phrases and HTTP codes in the text the CLI printed.
const RATE_LIMIT = /\b429\b|rate[ _-]?limit|too many requests|usage limit|quota|resource[_ ]exhausted/i;
const NOT_SIGNED_IN = /not logged in|not signed in|please (log|sign) in|unauthorized|\b401\b|invalid (api )?key|authentication (required|failed)/i;

/**
 * Names what went wrong. `exitCode` null means the binary couldn't be started; pass the text the CLI
 * printed on stderr plus any `error` event message. A run that exited 0 is not a failure.
 * Confirmed signals: codex prints "Not logged in" and exits 1 from `login status`; gemini exits 41
 * for authentication errors. Everything else is matched on the text (see the heuristics above).
 */
export function classifyFailure(
  id: EngineID,
  run: { exitCode: number | null; text: string },
): Failure | null {
  if (id !== "codex" && id !== "gemini") return null;
  const m = MESSAGES[id];
  if (run.exitCode === null) return { kind: "notInstalled", message: m.notInstalled };
  if (run.exitCode === 0) return null;  // an answer that mentions "quota" is not an error
  if (id === "gemini" && run.exitCode === 41) return { kind: "notSignedIn", message: m.notSignedIn };
  if (RATE_LIMIT.test(run.text)) return { kind: "rateLimited", message: m.rateLimited };
  if (NOT_SIGNED_IN.test(run.text)) return { kind: "notSignedIn", message: m.notSignedIn };
  const detail = run.text.trim().split("\n").filter(Boolean).pop() ?? "";
  return { kind: "failed", message: detail ? detail.slice(0, 300) : `${engineInfo(id).name} exited with code ${run.exitCode}.` };
}

/** `codex login status` result: exit 0 means signed in; the text is on stderr. */
export function codexSignedIn(exitCode: number | null, stderr: string): boolean {
  return exitCode === 0 && /logged in/i.test(stderr) && !/not logged in/i.test(stderr);
}
