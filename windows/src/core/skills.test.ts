import { test } from "node:test";
import assert from "node:assert/strict";
import { matchSkills, withSkill } from "./skills.ts";
import type { SkillInfo } from "./bridge";

const skill = (name: string, description = "", enabled = true): SkillInfo => ({
  name, description, enabled, source: "personal", origin: null, path: `/s/${name}`,
  editable: true, hasScripts: false, modified: 0,
});

test("skills: / lists enabled skills, name matches first", () => {
  const all = [skill("pdf", "Read PDF files"), skill("xlsx", "Spreadsheets, reads pdf exports too"), skill("old", "", false)];
  assert.deepEqual(matchSkills(all, "/").map((s) => s.name), ["pdf", "xlsx"]);
  assert.deepEqual(matchSkills(all, "/pd").map((s) => s.name), ["pdf", "xlsx"]);
  assert.deepEqual(matchSkills(all, "/XL").map((s) => s.name), ["xlsx"]);
  assert.deepEqual(matchSkills(all, "/old"), []);
});

test("skills: the picked skill's instructions go before the request", () => {
  const text = withSkill("pdf", "/s/pdf", "  # PDF\nSteps  ", "summarise report.pdf");
  assert.ok(text.startsWith('Use the skill "pdf" for this request (its folder: /s/pdf).'));
  assert.ok(text.includes("<skill>\n# PDF\nSteps\n</skill>"));
  assert.ok(text.endsWith("Request: summarise report.pdf"));
});
