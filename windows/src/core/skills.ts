// Skills in the chat: "/" lists them, and the picked one's SKILL.md goes with the
// next question, whatever the engine (Claude Code, the API, other providers).

import type { SkillInfo } from "./bridge";

/** The question sent with a skill picked with "/": its instructions, then the request. */
export function withSkill(name: string, path: string, content: string, query: string): string {
  return `Use the skill "${name}" for this request (its folder: ${path}). Its instructions:\n\n<skill>\n${content.trim()}\n</skill>\n\nRequest: ${query}`;
}

/** Skills whose name or description match what follows "/". */
export function matchSkills(skills: SkillInfo[], typed: string): SkillInfo[] {
  const q = typed.replace(/^\//, "").trim().toLowerCase();
  const on = skills.filter((s) => s.enabled);
  if (!q) return on.slice(0, 6);
  const starts = on.filter((s) => s.name.toLowerCase().startsWith(q));
  const rest = on.filter((s) => !starts.includes(s) && `${s.name} ${s.description}`.toLowerCase().includes(q));
  return [...starts, ...rest].slice(0, 6);
}
