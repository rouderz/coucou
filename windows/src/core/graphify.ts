// Graphify (https://github.com/Graphify-Labs/graphify): a knowledge graph of each project.
// Pure logic only (no I/O): finding the CLI, version check, the status of a project's
// `graphify-out/`, and trimming `graphify query` output before it goes into a chat.
// Mirrored in NotchBuddy/Sources/App/Graphify.swift (GraphifyLogic); keep both in step.
//
// Rules: Coucou never installs Python packages by itself (it only shows the command),
// builds with `--code-only` (local, no LLM, no network), writes only inside the project's
// `graphify-out/`, and starts no `--watch` process.

export const INSTALL_COMMAND = "uv tool install graphifyy";
export const OUT_DIR = "graphify-out";
/** Written by Coucou after a successful build, inside graphify-out/: the commit the graph was built at. */
export const STAMP_FILE = ".coucou-build.json";
/** Default size cap (characters) of a `graphify query` result attached to a chat. */
export const QUERY_CAP = 6000;

export type Platform = "mac" | "linux" | "windows";

// ---- Finding the CLI -------------------------------------------------------------------

/** Full paths where `graphify` may live, best first: PATH, uv's tool bin dir, ~/.local/bin. */
export function cliCandidates(platform: Platform, home: string, env: Record<string, string | undefined>): string[] {
  const win = platform === "windows";
  const sep = win ? "\\" : "/";
  const join = (dir: string, name: string) => (dir.endsWith(sep) ? dir + name : dir + sep + name);
  const names = win ? ["graphify.exe", "graphify.cmd", "graphify.bat"] : ["graphify"];
  const dirs: string[] = [];
  for (const d of (env.PATH ?? env.Path ?? "").split(win ? ";" : ":")) if (d.trim()) dirs.push(d.trim());
  // uv puts tool executables in UV_TOOL_BIN_DIR, else XDG_BIN_HOME, else ~/.local/bin.
  for (const d of [env.UV_TOOL_BIN_DIR, env.XDG_BIN_HOME]) if (d?.trim()) dirs.push(d.trim());
  if (home) dirs.push(join(join(home, ".local"), "bin"));
  const seen = new Set<string>();
  const out: string[] = [];
  for (const d of dirs) {
    const key = win ? d.toLowerCase() : d;
    if (seen.has(key)) continue;
    seen.add(key);
    for (const n of names) out.push(join(d, n));
  }
  return out;
}

export type Version = [number, number, number];

/** The first `x.y.z` in `graphify --version` output ("graphify 0.4.2", "v0.4.2", "0.4"). */
export function parseVersion(output: string): Version | null {
  const m = /(\d+)\.(\d+)(?:\.(\d+))?/.exec(output);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3] ?? 0)] : null;
}

export function compareVersions(a: Version, b: Version): number {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

export type CliStatus =
  | { state: "missing" }
  | { state: "unknown"; path: string } // found, but its version couldn't be read
  | { state: "old"; path: string; version: Version; min: Version }
  | { state: "ok"; path: string; version: Version };

/** `versionOutput` is what `<path> --version` printed, or null if it didn't run. */
export function cliStatus(path: string | null, versionOutput: string | null, min: Version | null = null): CliStatus {
  if (!path) return { state: "missing" };
  const version = versionOutput == null ? null : parseVersion(versionOutput);
  if (!version) return { state: "unknown", path };
  if (min && compareVersions(version, min) < 0) return { state: "old", path, version, min };
  return { state: "ok", path, version };
}

// ---- A project's graphify-out/ ------------------------------------------------------------

export interface Stamp { commit: string; builtAt: number }

export function isCommit(s: string): boolean {
  return /^[0-9a-f]{7,64}$/i.test(s);
}

/** Coucou's own stamp file. Anything unexpected is null (the graph then counts as "unknown"). */
export function parseStamp(text: string): Stamp | null {
  try {
    const o = JSON.parse(text);
    if (!o || typeof o.commit !== "string" || !isCommit(o.commit)) return null;
    return { commit: o.commit, builtAt: Number.isFinite(o.builtAt) ? Number(o.builtAt) : 0 };
  } catch {
    return null;
  }
}

export function stampText(commit: string, builtAt: number): string {
  return JSON.stringify({ commit, builtAt });
}

/** Node and edge counts from graph.json. The format isn't documented by graphify, so this is
 *  best effort: `nodes` and `edges` (or `links`) as arrays or objects; otherwise null. */
export function parseGraphCounts(text: string): { nodes: number; edges: number } | null {
  let o: unknown;
  try { o = JSON.parse(text); } catch { return null; }
  if (!o || typeof o !== "object") return null;
  const rec = o as Record<string, unknown>;
  const size = (v: unknown): number | null =>
    Array.isArray(v) ? v.length : v && typeof v === "object" ? Object.keys(v).length : null;
  const nodes = size(rec.nodes);
  const edges = size(rec.edges ?? rec.links);
  return nodes == null ? null : { nodes, edges: edges ?? 0 };
}

/** git arguments for the files changed between the build and HEAD. Null for anything that isn't a commit id. */
export function changedFilesArgs(commit: string): string[] | null {
  return isCommit(commit) ? ["diff", "--name-only", `${commit}..HEAD`] : null;
}

/** When there is no stamp: the last commit made before graph.json was written. */
export function builtAtCommitArgs(graphMtimeSeconds: number): string[] {
  return ["rev-list", "-1", `--before=${Math.max(0, Math.floor(graphMtimeSeconds))}`, "HEAD"];
}

/** Lines of `git diff --name-only`, without graphify-out/ (our own output isn't a change). */
export function parseChangedFiles(stdout: string): string[] {
  return stdout
    .split(/\r?\n/)
    .map((l) => l.trim().replace(/\\/g, "/"))
    .filter((l) => l && l !== OUT_DIR && !l.startsWith(OUT_DIR + "/"));
}

export type GraphStatus =
  | { state: "none" } // no graphify-out/graph.json
  | { state: "unknown" } // not a git repo, or the built-at commit is gone
  | { state: "fresh" }
  | { state: "stale"; changed: number; sample: string[] };

/** `changed` is parseChangedFiles of the diff, or null when git couldn't answer. */
export function graphStatus(hasGraph: boolean, changed: string[] | null, sampleSize = 5): GraphStatus {
  if (!hasGraph) return { state: "none" };
  if (changed == null) return { state: "unknown" };
  if (changed.length === 0) return { state: "fresh" };
  return { state: "stale", changed: changed.length, sample: changed.slice(0, sampleSize) };
}

// ---- graphify query output for the chat ---------------------------------------------------

const ANSI = /\u001b\[[0-9;?]*[ -/]*[@-~]/g;

/** Cleans and caps `graphify query` output (cap in characters): cut at a line, say how much was left out. */
export function trimQueryOutput(raw: string, cap: number = QUERY_CAP): string {
  const text = raw.replace(ANSI, "").replace(/\r\n?/g, "\n").trim();
  const len = (s: string) => Array.from(s).length;
  if (len(text) <= cap) return text;
  const lines = text.split("\n");
  const marker = (n: number) => `\n… ${n} more lines left out (capped at ${cap} characters)`;
  const room = Math.max(0, cap - len(marker(lines.length)));
  const kept: string[] = [];
  let used = 0;
  for (const line of lines) {
    const add = len(line) + (kept.length ? 1 : 0);
    if (used + add > room) break;
    kept.push(line);
    used += add;
  }
  if (kept.length === 0) {
    // One huge first line: cut it.
    return Array.from(lines[0]).slice(0, Math.max(0, cap - 1)).join("") + "…";
  }
  return kept.join("\n") + marker(lines.length - kept.length);
}
