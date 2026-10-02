// Codex CLI's `apply_patch` (#44 on macOS): the patch text, the files it touches,
// and a diff for the approval card. Port of CodexPatch in CodexCLI.swift.

export type PatchLineKind = "context" | "removed" | "added";

export interface PatchLine {
  kind: PatchLineKind;
  text: string;
}

export interface FileChange {
  path: string;
  kind: "update" | "add" | "delete";
  lines: PatchLine[];
}

/** The patch carried by a tool_input, whichever key Codex used for it. */
export function patchText(input: Record<string, unknown>): string | null {
  for (const key of ["command", "patch", "input"]) {
    const v = input[key];
    if (typeof v === "string" && v.includes("*** Begin Patch")) return v;
    if (Array.isArray(v)) {
      const hit = v.find((x) => typeof x === "string" && x.includes("*** Begin Patch"));
      if (typeof hit === "string") return hit;
    }
  }
  return null;
}

function header(line: string, prefix: string): string | null {
  if (!line.startsWith(prefix)) return null;
  const path = line.slice(prefix.length).trim();
  return path || null;
}

export function parsePatch(patch: string): FileChange[] {
  const changes: FileChange[] = [];
  for (const raw of patch.split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    const last = changes[changes.length - 1];
    let path: string | null;
    if ((path = header(line, "*** Update File: "))) changes.push({ path, kind: "update", lines: [] });
    else if ((path = header(line, "*** Add File: "))) changes.push({ path, kind: "add", lines: [] });
    else if ((path = header(line, "*** Delete File: "))) changes.push({ path, kind: "delete", lines: [] });
    else if ((path = header(line, "*** Move to: ")) && last) last.path = path;
    else if (line.startsWith("***") || !last) continue;
    else if (line.startsWith("@@")) {
      if (last.lines.length) last.lines.push({ kind: "context", text: "⋯" });
    } else if (line.startsWith("+")) last.lines.push({ kind: "added", text: line.slice(1) });
    else if (line.startsWith("-")) last.lines.push({ kind: "removed", text: line.slice(1) });
    else if (line.startsWith(" ")) last.lines.push({ kind: "context", text: line.slice(1) });
  }
  return changes;
}

/** Absolute against the session's folder (either slash style). */
export function absolutePath(path: string, cwd: string): string {
  if (!cwd || path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path) || path.startsWith("\\\\")) return path;
  const sep = cwd.includes("\\") && !cwd.includes("/") ? "\\" : "/";
  return cwd.replace(/[\\/]+$/, "") + sep + path;
}

export function patchFiles(patch: string, cwd: string): string[] {
  return parsePatch(patch).map((c) => absolutePath(c.path, cwd));
}
