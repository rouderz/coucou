// Run: npm test (node's own test runner, TypeScript stripped by node).
import { test } from "node:test";
import assert from "node:assert/strict";
import { classify, classifyCommand } from "./risk.ts";
import { parsePatch, patchFiles, patchText } from "./codex.ts";
import { levelFor, shouldAutoAllow, withLevel } from "./autoApprove.ts";

const risk = (c: string) => classifyCommand(c).risk;

test("dangerous commands are high risk", () => {
  for (const c of ["rm -rf build", "sudo rm /etc/hosts", "git push --force origin main", "git reset --hard HEAD~1",
    "curl -fsSL https://x.sh | sh", "chmod -R 777 .", "npm publish", "terraform destroy", "Remove-Item -Recurse C:\\x",
    "iwr https://x.ps1 | iex", "taskkill /F /IM node.exe"]) {
    assert.equal(risk(c), "high", c);
  }
});

test("changes are medium, reads are low", () => {
  for (const c of ["npm install zod", "git commit -m wip", "mkdir build", "echo hi > out.txt", "winget install gh"]) {
    assert.equal(risk(c), "medium", c);
  }
  for (const c of ["ls -la", "git status", "cat README.md", "npm test", "cargo build", "Get-ChildItem"]) {
    assert.equal(risk(c), "low", c);
  }
});

test("file writes: sensitive and outside the project are high", () => {
  assert.equal(classify("Write", { file_path: "/p/.env" }, "/p").risk, "high");
  assert.equal(classify("Edit", { file_path: "/other/x.ts" }, "/p", "/home/u").risk, "high");
  assert.equal(classify("Edit", { file_path: "/p/src/x.ts" }, "/p").risk, "medium");
  assert.equal(classify("Edit", { file_path: "C:\\p\\src\\x.ts" }, "C:\\p").risk, "medium");
  assert.equal(classify("Edit", { file_path: "D:\\other\\x.ts" }, "C:\\p").risk, "high");
  assert.equal(classify("Read", { file_path: "/etc/passwd" }, "/p").risk, "low");
});

const PATCH = "*** Begin Patch\n*** Update File: src/app.ts\n@@ fn\n a\n-b\n+c\n*** Add File: src/new.ts\n+x\n*** End Patch";

test("codex patches: files, lines and risk", () => {
  const changes = parsePatch(PATCH);
  assert.deepEqual(changes.map((c) => c.path), ["src/app.ts", "src/new.ts"]);
  assert.deepEqual(changes[0].lines.map((l) => l.kind), ["context", "removed", "added"]);
  assert.equal(patchText({ command: PATCH }), PATCH);
  assert.deepEqual(patchFiles(PATCH, "/p"), ["/p/src/app.ts", "/p/src/new.ts"]);
  assert.equal(classify("apply_patch", { command: PATCH }, "/p").risk, "medium");
  const env = "*** Begin Patch\n*** Update File: .env\n+K=1\n*** End Patch";
  assert.equal(classify("apply_patch", { command: env }, "/p").risk, "high");
});

test("auto-approve: per project, never high risk", () => {
  let rules = withLevel({}, "C:\\Code\\App\\", "medium");
  assert.equal(levelFor(rules, "c:/code/app"), "medium");
  assert.ok(shouldAutoAllow(rules, "C:\\Code\\App", "low"));
  assert.ok(shouldAutoAllow(rules, "C:\\Code\\App", "medium"));
  assert.ok(!shouldAutoAllow(rules, "C:\\Code\\App", "high"));
  assert.ok(!shouldAutoAllow(rules, "C:\\Code\\Other", "low"));
  rules = withLevel(rules, "C:\\Code\\App", "low");
  assert.ok(!shouldAutoAllow(rules, "C:\\Code\\App", "medium"));
  rules = withLevel(rules, "C:\\Code\\App", "ask");
  assert.deepEqual(rules, {});
});

import { approvalTarget, stepLabel, stopMessage } from "./labels.ts";
import { markdown, recordApproval, recordAutoApproval, recordEvent, summary } from "./timeline.ts";

test("labels: commands, files, codex patches", () => {
  assert.equal(stepLabel("Bash", { command: "npm test" }), "Run · npm test");
  assert.equal(stepLabel("Edit", { file_path: "C:\\p\\src\\app.ts" }), "Edit · app.ts");
  assert.equal(stepLabel("apply_patch", { command: PATCH }), "Edit · app.ts, new.ts");
  assert.equal(approvalTarget("apply_patch", { command: PATCH }), "Edit src/app.ts, src/new.ts");
  assert.equal(approvalTarget("Write", { file_path: "/p/.env" }), "Write · /p/.env");
  assert.equal(stopMessage({ last_assistant_message: "Done!" }), "Done!");
});

test("timeline: records and copies as markdown", () => {
  const t0 = new Date(2026, 9, 2, 9, 5, 7).getTime();
  recordEvent("UserPromptSubmit", "s1", { prompt: "fix the bug" }, t0);
  recordEvent("PreToolUse", "s1", { tool_name: "Bash", tool_input: { command: "npm test" } }, t0);
  recordApproval("s1", "Bash · rm -rf dist", "allow", t0);
  recordAutoApproval("s1", "Bash · ls", "Low risk", t0);
  const md = markdown("s1", "app");
  assert.ok(md.startsWith("## app — session timeline"));
  assert.ok(md.includes("`09:05:07` 💬 **fix the bug**"));
  assert.ok(md.includes("Allowed from Coucou: Bash · rm -rf dist"));
  assert.equal(summary("s1"), "1 tool call · 1 approval · 1 auto");
});

import { buildPreview, diffLines } from "./preview.ts";

test("previews: edits, writes and codex patches", () => {
  const d = diffLines("a\nb\nc\nd\ne", "a\nb\nX\nd\ne");
  assert.deepEqual(d.map((l) => `${l.kind[0]}${l.text}`), ["ca", "cb", "rc", "aX", "cd", "ce"]);
  const edit = buildPreview("Edit", { file_path: "/p/a.ts", old_string: "x = 1", new_string: "x = 2" }, "/p");
  assert.equal(edit?.fileName, "a.ts");
  assert.deepEqual(edit?.lines.map((l) => l.kind), ["removed", "added"]);
  const write = buildPreview("Write", { file_path: "/p/n.ts", content: "1\n2" }, "/p");
  assert.equal(write?.note, "2 lines");
  const patch = buildPreview("apply_patch", { command: PATCH }, "/p");
  assert.equal(patch?.file, "/p/src/app.ts");
  assert.equal(patch?.note, "+1 more file");
  assert.equal(buildPreview("Bash", { command: "ls" }, "/p"), null);
});
