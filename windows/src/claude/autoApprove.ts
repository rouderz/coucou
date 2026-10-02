// Auto-approve per project (#29 on macOS): "ask" every time, or answer low (or
// low and medium) risk requests at once. High risk always asks.

import { riskAtMost, type Risk } from "./risk.ts";

export type AutoLevel = "ask" | "low" | "medium";

export const AUTO_LEVELS: { id: AutoLevel; label: string }[] = [
  { id: "ask", label: "Always ask" },
  { id: "low", label: "Low risk" },
  { id: "medium", label: "Low + medium" },
];

/** Project key: the session folder, slashes and case normalised. */
export function projectKey(cwd: string): string {
  return cwd.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
}

export function levelFor(rules: Record<string, string>, cwd: string): AutoLevel {
  const v = rules[projectKey(cwd)];
  return v === "low" || v === "medium" ? v : "ask";
}

export function shouldAutoAllow(rules: Record<string, string>, cwd: string, risk: Risk): boolean {
  if (!cwd) return false;
  const level = levelFor(rules, cwd);
  return level !== "ask" && risk !== "high" && riskAtMost(risk, level);
}

/** A copy of the rules with this project's level set ("ask" removes it). */
export function withLevel(rules: Record<string, string>, cwd: string, level: AutoLevel): Record<string, string> {
  const next = { ...rules };
  if (level === "ask") delete next[projectKey(cwd)];
  else next[projectKey(cwd)] = level;
  return next;
}
