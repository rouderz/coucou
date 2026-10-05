import { test } from "node:test";
import assert from "node:assert/strict";
import { conversation, isCliEngine, readRun, KEPT_TURNS } from "./cliChat.ts";

test("only the CLI engines go through the CLI runner", () => {
  assert.ok(isCliEngine("codex"));
  assert.ok(isCliEngine("gemini"));
  assert.ok(!isCliEngine("claude-code"));
  assert.ok(!isCliEngine("api"));
});

test("the conversation carries the recent turns, the context and the question", () => {
  const text = conversation(
    [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }],
    { kind: "window", appName: "Chrome", title: "Docs" },
    "and now?",
  );
  assert.match(text, /User: hi\n\nAssistant: hello/);
  assert.match(text, /Context — App: Chrome, Window: Docs/);
  assert.ok(text.endsWith("User: and now?"));
  assert.equal(conversation([], null, "q"), "User: q");
  const long = Array.from({ length: 40 }, (_, i) => ({ role: "user" as const, content: `m${i}` }));
  assert.ok(!conversation(long, null, "q").includes("m0\n"));
  assert.equal((conversation(long, null, "q").match(/User: m/g) ?? []).length, KEPT_TURNS);
});

test("reads a Codex answer and names its failures", () => {
  const stdout = [
    '{"type":"thread.started","thread_id":"t1"}',
    '{"type":"item.completed","item":{"type":"agent_message","text":"Hola"}}',
    '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":2}}',
  ].join("\n");
  assert.equal(readRun("codex", { exitCode: 0, stdout, stderr: "" }), "Hola");
  assert.throws(() => readRun("codex", { exitCode: null, stdout: "", stderr: "" }), /isn't installed/);
  assert.throws(() => readRun("codex", { exitCode: 1, stdout: "", stderr: "Not logged in" }), /codex login/);
});

test("reads a Gemini stream", () => {
  const stdout = [
    '{"type":"init","session_id":"s"}',
    '{"type":"message","role":"assistant","content":"Ho","delta":true}',
    '{"type":"message","role":"assistant","content":"la","delta":true}',
    '{"type":"result","status":"success","stats":{"input_tokens":1,"output_tokens":1}}',
  ].join("\n");
  assert.equal(readRun("gemini", { exitCode: 0, stdout, stderr: "" }), "Hola");
  assert.throws(() => readRun("gemini", { exitCode: 41, stdout: "", stderr: "" }), /isn't signed in/);
});
