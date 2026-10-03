// Run: npm test. Payloads are built from the official docs' field lists (Gemini:
// docs/hooks/reference.md + docs/reference/tools.md; Cursor: cursor.com/docs/hooks
// as quoted by search results and public examples). None was recorded from a real run.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  answerFor, backupName, cursorHasOurs, cursorInstalled, cursorUninstalled, geminiDenyByExit,
  geminiHasOurs, geminiInstalled, geminiUninstalled, mapCursor, mapGemini, planChange, relayCommand,
  unifiedDiff, type Json,
} from "./agents.ts";
import { classifyCommand } from "./risk.ts";

const cursorBase = {
  conversation_id: "conv-1", generation_id: "gen-1", model: "composer", hook_event_name: "",
  cursor_version: "1.7.2", workspace_roots: ["/work/app"], user_email: null,
};
const geminiBase = {
  session_id: "g-1", transcript_path: "/t.json", cwd: "/work/app", hook_event_name: "", timestamp: "2026-10-03T10:00:00Z",
};

test("cursor: shell and MCP gates become permission requests", () => {
  const shell = mapCursor({ ...cursorBase, hook_event_name: "beforeShellExecution", command: "rm -rf build", cwd: "/work/app/sub", sandbox: false });
  assert.equal(shell?.waits, true);
  assert.deepEqual(shell?.event, {
    agent: "cursor", session_id: "conv-1", cwd: "/work/app/sub", hook_event_name: "PermissionRequest",
    tool_name: "Bash", tool_input: { command: "rm -rf build" },
  });
  assert.equal(classifyCommand((shell!.event.tool_input as Json).command as string).risk, "high");

  const mcp = mapCursor({
    ...cursorBase, hook_event_name: "beforeMCPExecution", mcp_server_name: "linear",
    tool_name: "create_issue", tool_input: '{"title":"x"}',
  });
  assert.equal(mcp?.event.tool_name, "mcp__linear__create_issue");
  assert.deepEqual(mcp?.event.tool_input, { title: "x" });
  assert.equal(mcp?.waits, true);
});

test("cursor: lifecycle events, cwd from workspace_roots, stop status", () => {
  const start = mapCursor({ ...cursorBase, hook_event_name: "sessionStart", session_id: "s", composer_mode: "agent" });
  assert.equal(start?.event.hook_event_name, "SessionStart");
  assert.equal(start?.event.cwd, "/work/app");
  assert.equal(start?.event.session_id, "conv-1");
  assert.equal(start?.waits, false);
  assert.equal(mapCursor({ ...cursorBase, hook_event_name: "beforeSubmitPrompt" })?.event.hook_event_name, "UserPromptSubmit");
  assert.equal(mapCursor({ ...cursorBase, hook_event_name: "stop", status: "completed", loop_count: 0 })?.event.hook_event_name, "Stop");
  assert.equal(mapCursor({ ...cursorBase, hook_event_name: "stop", status: "aborted" })?.event.hook_event_name, "Stop");
  assert.equal(mapCursor({ ...cursorBase, hook_event_name: "stop", status: "error" })?.event.hook_event_name, "StopFailure");
  assert.equal(mapCursor({ ...cursorBase, hook_event_name: "sessionEnd" })?.event.hook_event_name, "SessionEnd");
  const edit = mapCursor({ ...cursorBase, hook_event_name: "afterFileEdit", file_path: "src/a.ts", edits: [{ new_string: "x" }] });
  assert.deepEqual(edit?.event.tool_input, { file_path: "src/a.ts" });
});

test("cursor: unknown events, missing ids and empty commands map to nothing", () => {
  assert.equal(mapCursor({ ...cursorBase, hook_event_name: "somethingNew" }), null);
  assert.equal(mapCursor({ hook_event_name: "stop" }), null);
  assert.equal(mapCursor({ ...cursorBase, hook_event_name: "beforeShellExecution" }), null);
  assert.equal(mapCursor({}), null);
});

test("gemini: BeforeTool is the gate, tool names follow Claude Code's", () => {
  const m = mapGemini({
    ...geminiBase, hook_event_name: "BeforeTool", tool_name: "run_shell_command",
    tool_input: { command: "git push --force", description: "push" },
  });
  assert.equal(m?.waits, true);
  assert.equal(m?.event.hook_event_name, "PermissionRequest");
  assert.equal(m?.event.tool_name, "Bash");
  assert.equal(m?.event.agent, "gemini");
  assert.equal(classifyCommand((m!.event.tool_input as Json).command as string).risk, "high");

  const w = mapGemini({ ...geminiBase, hook_event_name: "BeforeTool", tool_name: "write_file", tool_input: { file_path: "/work/app/a.ts", content: "x" } });
  assert.equal(w?.event.tool_name, "Write");
  const r = mapGemini({ ...geminiBase, hook_event_name: "BeforeTool", tool_name: "replace", tool_input: { file_path: "a", old_string: "a", new_string: "b" } });
  assert.equal(r?.event.tool_name, "Edit");
  const other = mapGemini({ ...geminiBase, hook_event_name: "BeforeTool", tool_name: "tracker_create_task", tool_input: { title: "t" } });
  assert.equal(other?.event.tool_name, "tracker_create_task");
});

test("gemini: lifecycle, prompt, response and notification", () => {
  assert.equal(mapGemini({ ...geminiBase, hook_event_name: "SessionStart", source: "startup" })?.event.hook_event_name, "SessionStart");
  assert.equal(mapGemini({ ...geminiBase, hook_event_name: "SessionEnd", reason: "exit" })?.event.hook_event_name, "SessionEnd");
  const prompt = mapGemini({ ...geminiBase, hook_event_name: "BeforeAgent", prompt: "fix the bug" });
  assert.equal(prompt?.event.hook_event_name, "UserPromptSubmit");
  assert.equal(prompt?.event.prompt, "fix the bug");
  const stop = mapGemini({ ...geminiBase, hook_event_name: "AfterAgent", prompt: "p", prompt_response: "Done.", stop_hook_active: false });
  assert.equal(stop?.event.hook_event_name, "Stop");
  assert.equal(stop?.event.last_assistant_message, "Done.");
  const after = mapGemini({ ...geminiBase, hook_event_name: "AfterTool", tool_name: "glob", tool_input: { pattern: "*" }, tool_response: {} });
  assert.equal(after?.event.hook_event_name, "PostToolUse");
  assert.equal(after?.waits, false);
  const note = mapGemini({ ...geminiBase, hook_event_name: "Notification", notification_type: "ToolPermission", message: "Allow?", details: {} });
  assert.equal(note?.event.message, "Allow?");
  assert.equal(mapGemini({ ...geminiBase, hook_event_name: "BeforeModel" }), null);
  assert.equal(mapGemini({ hook_event_name: "BeforeTool" }), null);
});

test("answers: Cursor permission, Gemini decision, silence otherwise", () => {
  const c = (a: string, ev = "beforeShellExecution") => answerFor("cursor", ev, a);
  assert.deepEqual(JSON.parse(c("allow").stdout!), { permission: "allow" });
  assert.deepEqual(JSON.parse(c("always").stdout!), { permission: "allow" });
  assert.deepEqual(JSON.parse(c("ask", "beforeMCPExecution").stdout!), { permission: "ask" });
  const deny = JSON.parse(c("deny").stdout!);
  assert.equal(deny.permission, "deny");
  assert.ok(deny.user_message && deny.agent_message);
  assert.equal(c("maybe").stdout, null);
  assert.equal(c("allow", "afterFileEdit").stdout, null);

  const g = (a: string, ev = "BeforeTool") => answerFor("gemini", ev, a);
  assert.deepEqual(JSON.parse(g("allow").stdout!), { decision: "allow" });
  assert.deepEqual(JSON.parse(g("always").stdout!), { decision: "allow" });
  assert.deepEqual(JSON.parse(g("deny").stdout!), { decision: "deny", reason: "Denied from Coucou" });
  assert.equal(g("ask").stdout, null, "Gemini has no ask: stay silent");
  assert.equal(g("allow", "AfterTool").stdout, null);
  assert.equal(g("").stdout, null);
  assert.equal(g("deny").exit, 0);
  assert.deepEqual(geminiDenyByExit("no"), { stdout: null, exit: 2, stderr: "no" });
});

const CMD_C = relayCommand("C:\\Apps\\coucou-hook.exe", "cursor");
const CMD_G = relayCommand("/x/coucou-hook", "gemini");

test("relay command is quoted with forward slashes", () => {
  assert.equal(CMD_C, '"C:/Apps/coucou-hook.exe" --agent cursor');
});

test("cursor config: merge keeps the user's hooks, idempotent, clean removal", () => {
  const mine = { version: 1, hooks: { beforeShellExecution: [{ command: "./my-policy.sh" }], preToolUse: [{ command: "./x.sh" }] }, other: { a: 1 } };
  const once = cursorInstalled(mine, CMD_C) as any;
  assert.equal(once.other.a, 1);
  assert.deepEqual(once.hooks.beforeShellExecution[0], { command: "./my-policy.sh" });
  assert.equal(once.hooks.beforeShellExecution.length, 2);
  assert.deepEqual(once.hooks.preToolUse, [{ command: "./x.sh" }], "preToolUse is not ours");
  assert.ok(cursorHasOurs(once));
  assert.deepEqual(cursorInstalled(once, CMD_C), once, "idempotent");
  assert.deepEqual(cursorUninstalled(once), mine, "removal restores the user's file");
  assert.deepEqual(mine.hooks.beforeShellExecution, [{ command: "./my-policy.sh" }], "input not mutated");
  assert.deepEqual(cursorUninstalled(cursorInstalled({}, CMD_C)), { version: 1 });
  assert.equal(cursorHasOurs({}), false);
  assert.equal((cursorInstalled({}, CMD_C) as any).version, 1);
  assert.equal((cursorInstalled({ version: 2 }, CMD_C) as any).version, 2);
});

test("gemini config: merge keeps settings and hooks, idempotent, clean removal", () => {
  const mine = {
    theme: "Dark", mcpServers: { a: { command: "x" } },
    hooks: { BeforeTool: [{ matcher: "write_file", hooks: [{ type: "command", command: "./lint.sh" }] }], BeforeModel: [{ hooks: [{ type: "command", command: "./m.sh" }] }] },
  };
  const once = geminiInstalled(mine, CMD_G) as any;
  assert.equal(once.theme, "Dark");
  assert.deepEqual(once.mcpServers, mine.mcpServers);
  assert.equal(once.hooks.BeforeTool.length, 2);
  assert.equal(once.hooks.BeforeTool[0].matcher, "write_file");
  assert.equal(once.hooks.BeforeTool[1].hooks[0].timeout, 120000);
  assert.equal(once.hooks.SessionStart[0].hooks[0].command, CMD_G);
  assert.deepEqual(once.hooks.BeforeModel, mine.hooks.BeforeModel);
  assert.ok(geminiHasOurs(once));
  assert.deepEqual(geminiInstalled(once, CMD_G), once, "idempotent");
  assert.deepEqual(geminiUninstalled(once), mine);
  assert.deepEqual(geminiUninstalled(geminiInstalled({ theme: "x" }, CMD_G)), { theme: "x" });
  assert.equal(geminiHasOurs({ hooks: { BeforeTool: [{ hooks: [{ command: "./lint.sh" }] }] } }), false);
});

test("planChange: diff, no-op, BOM, empty file and refusals", () => {
  const empty = planChange("cursor", null, CMD_C, true);
  assert.ok(empty.ok && empty.changed);
  assert.ok(empty.ok && empty.diff.split("\n").every((l) => l.startsWith("+")));

  const existing = JSON.stringify({ theme: "Dark" }, null, 2) + "\n";
  const plan = planChange("gemini", "\uFEFF" + existing, CMD_G, true);
  assert.ok(plan.ok && plan.changed);
  assert.ok(plan.ok && plan.diff.includes('+  "hooks": {'));
  // The only removed line is the user's last key gaining a comma.
  assert.deepEqual(plan.ok && plan.diff.split("\n").filter((l) => l.startsWith("-")), ['-  "theme": "Dark"']);

  const again = planChange("gemini", plan.ok ? plan.after : "", CMD_G, true);
  assert.ok(again.ok && !again.changed && again.diff === "");

  const out = planChange("gemini", plan.ok ? plan.after : "", CMD_G, false);
  assert.ok(out.ok && out.after === existing);

  const nothing = planChange("cursor", null, CMD_C, false);
  assert.ok(nothing.ok && !nothing.changed);

  for (const bad of ["{ nope", "[1,2]", "42"]) {
    const r = planChange("cursor", bad, CMD_C, true);
    assert.ok(!r.ok && r.error.includes("won't touch"), bad);
  }
});

test("backup name and diff basics", () => {
  assert.equal(backupName("/h/.cursor/hooks.json", new Date(Date.UTC(2026, 9, 3, 14, 5, 1))), "/h/.cursor/hooks.json.bak-20261003-140501");
  assert.equal(unifiedDiff("a\nb\n", "a\nb\n"), "");
  assert.equal(unifiedDiff("a\nb\nc\n", "a\nX\nc\n"), " a\n-b\n+X\n c");
});
