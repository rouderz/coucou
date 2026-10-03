import { test } from "node:test";
import assert from "node:assert/strict";
import {
  AnswerBuilder, candidatePaths, classifyFailure, codexSignedIn, ENGINES, installDirs, invocation,
  parseCodexLine, parseGeminiJSON, parseGeminiLine, parseLine, runnableEngines, signInCheck,
} from "./chatEngines.ts";

// The samples below are written to match the event types defined in the CLIs' own sources
// (codex-rs/exec/src/exec_events.rs, gemini-cli packages/core/src/output/types.ts). They are
// NOT recordings of a real run: no CLI was available when these tests were written.

const CODEX = [
  '{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}',
  '{"type":"turn.started"}',
  '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}',
  '{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"Thinking"}}',
  '{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Hello there."}}',
  '{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Anything else?"}}',
  '{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}',
];

const GEMINI = [
  '{"type":"init","timestamp":"2025-10-10T12:00:00.000Z","session_id":"abc-123","model":"gemini-2.5-pro"}',
  '{"type":"message","timestamp":"2025-10-10T12:00:01.000Z","role":"user","content":"Hi"}',
  '{"type":"message","timestamp":"2025-10-10T12:00:02.000Z","role":"assistant","content":"Hel","delta":true}',
  '{"type":"tool_use","timestamp":"2025-10-10T12:00:02.500Z","tool_name":"read_file","tool_id":"t1","parameters":{}}',
  '{"type":"error","timestamp":"2025-10-10T12:00:02.600Z","severity":"warning","message":"Loop detected"}',
  '{"type":"message","timestamp":"2025-10-10T12:00:03.000Z","role":"assistant","content":"lo!","delta":true}',
  '{"type":"result","timestamp":"2025-10-10T12:00:04.000Z","status":"success","stats":{"total_tokens":30,"input_tokens":20,"output_tokens":10,"cached":0,"input":20,"duration_ms":900,"tool_calls":1,"models":{}}}',
];

test("codex: agent messages become text, usage and done close the turn", () => {
  const b = new AnswerBuilder("codex");
  for (const l of CODEX) b.push(parseCodexLine(l));
  assert.equal(b.sessionID, "0199a213-81c0-7800-8aa1-bbab2a035a53");
  assert.equal(b.text, "Hello there.\n\nAnything else?");
  assert.deepEqual(b.usage, { inputTokens: 24763, outputTokens: 122 });
  assert.equal(b.done, true);
  assert.equal(b.error, null);
});

test("codex: failures and fatal errors surface, junk lines are skipped", () => {
  assert.deepEqual(parseCodexLine('{"type":"turn.failed","error":{"message":"boom"}}'), [{ kind: "error", message: "boom" }]);
  assert.deepEqual(parseCodexLine('{"type":"error","message":"fatal"}'), [{ kind: "error", message: "fatal" }]);
  assert.deepEqual(parseCodexLine("Reading prompt from stdin..."), []);
  assert.deepEqual(parseCodexLine("{not json"), []);
  assert.deepEqual(parseCodexLine('{"type":"item.completed","item":{"type":"file_change","changes":[],"status":"completed"}}'), []);
});

test("gemini: assistant chunks are glued, user echoes and warnings ignored", () => {
  const b = new AnswerBuilder("gemini");
  for (const l of GEMINI) b.push(parseGeminiLine(l));
  assert.equal(b.sessionID, "abc-123");
  assert.equal(b.text, "Hello!");
  assert.deepEqual(b.usage, { inputTokens: 20, outputTokens: 10 });
  assert.equal(b.done, true);
  assert.equal(b.error, null);
});

test("gemini: error result and severity error", () => {
  assert.deepEqual(
    parseGeminiLine('{"type":"result","timestamp":"t","status":"error","error":{"type":"Error","message":"quota"}}'),
    [{ kind: "error", message: "quota" }],
  );
  assert.deepEqual(parseGeminiLine('{"type":"error","timestamp":"t","severity":"error","message":"x"}'), [{ kind: "error", message: "x" }]);
});

test("gemini: single JSON object, answer or error", () => {
  const ok = parseGeminiJSON('{"session_id":"s1","response":"Hi","stats":{"models":{}}}');
  assert.deepEqual(ok, [{ kind: "session", id: "s1" }, { kind: "text", text: "Hi" }, { kind: "done" }]);
  const bad = parseGeminiJSON('{"error":{"type":"ApiError","message":"nope","code":429}}');
  assert.deepEqual(bad, [{ kind: "error", message: "nope" }]);
  assert.deepEqual(parseGeminiJSON("not json"), []);
});

test("invocation: only the confirmed CLIs, chats never leave codex's read-only sandbox", () => {
  assert.deepEqual(invocation("codex", "hi"), ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "hi"]);
  assert.deepEqual(invocation("codex", "hi", { model: " gpt-5 " }).slice(-3), ["--model", "gpt-5", "hi"]);
  assert.deepEqual(invocation("gemini", "hi"), ["--output-format", "stream-json", "--prompt", "hi"]);
  assert.equal(invocation("cursor", "hi"), null);
  assert.equal(invocation("grok", "hi"), null);
  for (const id of ["codex", "gemini"] as const) {
    const args = invocation(id, "hi")!;
    assert.ok(!args.includes("--yolo") && !args.includes("yolo") && !args.includes("auto_edit"));
    assert.ok(!args.includes("danger-full-access") && !args.includes("--dangerously-bypass-approvals-and-sandbox"));
  }
  assert.deepEqual(signInCheck("codex"), ["login", "status"]);
  assert.equal(signInCheck("gemini"), null);
  assert.deepEqual(runnableEngines().map((e) => e.id), ["codex", "gemini"]);
  assert.ok(ENGINES.filter((e) => !e.confirmed).every((e) => e.loginCommand === null));
});

test("detection: PATH first, then the usual install folders, no duplicates", () => {
  const mac = candidatePaths("codex", { pathEnv: "/usr/local/bin:/opt/x/bin/", home: "/Users/a", platform: "mac" });
  assert.deepEqual(mac.slice(0, 2), ["/usr/local/bin/codex", "/opt/x/bin/codex"]);
  assert.ok(mac.includes("/opt/homebrew/bin/codex") && mac.includes("/Users/a/.npm-global/bin/codex"));
  assert.equal(new Set(mac).size, mac.length);
  const win = candidatePaths("gemini", { pathEnv: "C:\\bin;C:\\Users\\a\\AppData\\Roaming\\npm", home: "C:\\Users\\a", platform: "windows" });
  assert.equal(win[0], "C:\\bin\\gemini.cmd");
  assert.equal(win.filter((p) => p === "C:\\Users\\a\\AppData\\Roaming\\npm\\gemini.cmd").length, 1);
  assert.ok(installDirs("/home/a", "linux").includes("/home/a/.local/bin"));
});

test("failures: not installed, not signed in, rate limited", () => {
  assert.equal(classifyFailure("codex", { exitCode: null, text: "" })?.kind, "notInstalled");
  assert.match(classifyFailure("codex", { exitCode: 1, text: "Not logged in" })!.message, /`codex login`/);
  assert.equal(classifyFailure("gemini", { exitCode: 41, text: "" })?.kind, "notSignedIn");
  assert.equal(classifyFailure("gemini", { exitCode: 1, text: "Error 429: quota exceeded" })?.kind, "rateLimited");
  assert.equal(classifyFailure("codex", { exitCode: 1, text: "You've hit your usage limit" })?.kind, "rateLimited");
  assert.equal(classifyFailure("codex", { exitCode: 1, text: "weird\nlast line" })?.message, "last line");
  assert.equal(classifyFailure("codex", { exitCode: 3, text: "" })?.message, "Codex exited with code 3.");
  assert.equal(classifyFailure("codex", { exitCode: 0, text: "the quota is 5" }), null);
  assert.equal(classifyFailure("cursor", { exitCode: 1, text: "x" }), null);
});

test("codex login status: exit 0 and a logged-in line on stderr", () => {
  assert.equal(codexSignedIn(0, "Logged in using ChatGPT\n"), true);
  assert.equal(codexSignedIn(1, "Not logged in\n"), false);
  assert.equal(codexSignedIn(0, "Not logged in"), false);
  assert.equal(codexSignedIn(null, ""), false);
});

test("parseLine dispatches by engine", () => {
  assert.equal(parseLine("codex", CODEX[0]).length, 1);
  assert.equal(parseLine("gemini", GEMINI[0]).length, 1);
  assert.deepEqual(parseLine("grok", GEMINI[0]), []);
});
