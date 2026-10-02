// The change an edit approval would make, as a small diff (the macOS live view,
// EditPreviewBuilder). Built from the hook's tool_input alone: the island never
// reads the user's files.

import { absolutePath, parsePatch, patchText, type PatchLine } from "./codex.ts";
import { lastPathComponent } from "./labels.ts";

export interface EditPreview {
  file: string;
  fileName: string;
  lines: PatchLine[];
  note: string | null;
}

const MAX_LINES = 200;
const CONTEXT = 2;

/** Old → new text as removed / added lines; unchanged lines at both ends stay as context. */
export function diffLines(oldText: string, newText: string): PatchLine[] {
  const a = oldText.split("\n");
  const b = newText.split("\n");
  let start = 0;
  while (start < a.length - 1 && start < b.length - 1 && a[start] === b[start]) start++;
  let endA = a.length - 1;
  let endB = b.length - 1;
  while (endA > start && endB > start && a[endA] === b[endB]) {
    endA--;
    endB--;
  }
  const lines: PatchLine[] = [];
  for (let i = Math.max(0, start - CONTEXT); i < start; i++) lines.push({ kind: "context", text: a[i] });
  for (let i = start; i <= endA; i++) lines.push({ kind: "removed", text: a[i] });
  for (let i = start; i <= endB; i++) lines.push({ kind: "added", text: b[i] });
  for (let i = endA + 1; i < Math.min(a.length, endA + 1 + CONTEXT); i++) lines.push({ kind: "context", text: a[i] });
  return lines.slice(0, MAX_LINES);
}

export function buildPreview(tool: string, input: Record<string, unknown>, cwd: string): EditPreview | null {
  const str = (k: string, from: Record<string, unknown> = input) =>
    typeof from[k] === "string" ? (from[k] as string) : null;
  const make = (file: string, lines: PatchLine[], note: string | null): EditPreview =>
    ({ file, fileName: lastPathComponent(file), lines: lines.slice(0, MAX_LINES), note });

  const patch = patchText(input);
  if (patch) {
    const changes = parsePatch(patch);
    const first = changes[0];
    if (!first) return null;
    const notes: string[] = [];
    if (first.kind === "add") notes.push("new file");
    if (first.kind === "delete") notes.push("deletes the file");
    if (changes.length > 1) notes.push(`+${changes.length - 1} more file${changes.length > 2 ? "s" : ""}`);
    return make(absolutePath(first.path, cwd), first.lines, notes.join(" · ") || null);
  }

  const file = str("file_path");
  if (!file) return null;
  switch (tool) {
    case "Edit": {
      const o = str("old_string"), n = str("new_string");
      return o == null || n == null ? null : make(file, diffLines(o, n), null);
    }
    case "MultiEdit": {
      const edits = Array.isArray(input.edits) ? (input.edits as Record<string, unknown>[]) : [];
      const first = edits[0];
      const o = first && str("old_string", first), n = first && str("new_string", first);
      if (o == null || n == null) return null;
      const more = edits.length - 1;
      return make(file, diffLines(o, n), more > 0 ? `+${more} more edit${more > 1 ? "s" : ""}` : null);
    }
    case "Write": {
      const content = str("content") ?? "";
      const all = content.split("\n");
      return make(file, all.map((text) => ({ kind: "added" as const, text })),
        `${all.length} line${all.length === 1 ? "" : "s"}`);
    }
    default:
      return null;
  }
}
