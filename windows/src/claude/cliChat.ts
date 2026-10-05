// Codex / Gemini CLI chat engines (#108) on Windows/Linux: builds the conversation the CLI
// gets on stdin (Rust adds Mochi's instructions and runs it: src-tauri/src/cli_chat.rs) and
// reads its output with the tested parsers in chatEngines.ts.

import type { ChatContext } from "../core/bridge";
import { AnswerBuilder, classifyFailure, parseGeminiJSON, parseLine, type EngineID } from "./chatEngines.ts";

export type CliEngine = "codex" | "gemini";

export function isCliEngine(engine: string): engine is CliEngine {
  return engine === "codex" || engine === "gemini";
}

/** Turns kept as context: the CLI is asked fresh each time and gets them as text. */
export const KEPT_TURNS = 12;

/** The attached context as text (these engines can't open the dropped file itself). */
export function describeContext(ctx: ChatContext | null): string {
  if (!ctx) return "";
  if (ctx.kind === "window") return `Context — App: ${ctx.appName}, Window: ${ctx.title}${ctx.url ? `, URL: ${ctx.url}` : ""}`;
  if (ctx.kind === "file") return `The user attached a file named ${ctx.name} (this engine can't open it).`;
  let text = `The user is working on ${ctx.file}${ctx.workspace ? ` in ${ctx.workspace}` : ""}`;
  if (ctx.line) text += `, line ${ctx.line}`;
  if (ctx.selection) text += `.\nSelected code:\n${ctx.selection.slice(0, 4000)}`;
  return text;
}

/** The recent turns, the context and the new question, as one text. */
export function conversation(
  history: { role: "user" | "assistant"; content: string }[],
  context: ChatContext | null,
  query: string,
): string {
  const turns = history.slice(-KEPT_TURNS);
  let out = "";
  if (turns.length) {
    out += "Conversation so far:\n";
    for (const t of turns) out += `${t.role === "user" ? "User" : "Assistant"}: ${t.content}\n\n`;
    out += "---\n";
  }
  const ctx = describeContext(context);
  if (ctx) out += ctx + "\n\n";
  return out + "User: " + query;
}

/** Reads one run of the CLI: the answer, or an error in words the user can act on. */
export function readRun(engine: CliEngine, run: { exitCode: number | null; stdout: string; stderr: string }): string {
  const answer = new AnswerBuilder(engine as EngineID);
  for (const line of run.stdout.split("\n")) answer.push(parseLine(engine as EngineID, line));
  if (!answer.text && engine === "gemini") answer.push(parseGeminiJSON(run.stdout));
  const failure = classifyFailure(engine as EngineID, {
    exitCode: run.exitCode,
    text: [answer.error ?? "", run.stderr].filter(Boolean).join("\n"),
  });
  if (failure) throw new Error(failure.message);
  const text = answer.text.trim();
  if (!text) throw new Error(answer.error ?? "The engine gave no answer. Try again.");
  return text;
}

/** The engine hit a limit, or can't be used at all (not installed / signed out): try the next one. */
export function isOutOfQuota(message: string): boolean {
  return /\b429\b|rate[ _-]?limit|usage limit|hit (its|your|the) limit|limit reached|quota|too many requests|overloaded|isn't installed|not installed|isn't signed in|not signed in|not logged in/i.test(message);
}
