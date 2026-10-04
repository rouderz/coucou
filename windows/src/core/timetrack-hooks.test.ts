import { test } from "node:test";
import assert from "node:assert/strict";
import { hookTimeKind, recentPeriods } from "./timetrack.ts";

test("hook events map to time events", () => {
  assert.equal(hookTimeKind("SessionStart"), "start");
  assert.equal(hookTimeKind("UserPromptSubmit"), "prompt");
  assert.equal(hookTimeKind("PreToolUse"), "activity");
  assert.equal(hookTimeKind("PostToolUseFailure"), "activity");
  assert.equal(hookTimeKind("PermissionRequest"), "activity");
  assert.equal(hookTimeKind("Stop"), "stop");
  assert.equal(hookTimeKind("SessionEnd"), "stop");
  assert.equal(hookTimeKind("Notification", { notification_type: "idle_prompt" }), "idle");
  assert.equal(hookTimeKind("Notification", { message: "Claude is waiting for your input" }), "idle");
  assert.equal(hookTimeKind("Notification", { message: "Claude needs your permission to use Bash" }), null);
  assert.equal(hookTimeKind("StatusLine"), null);
  assert.equal(hookTimeKind("EditorContext"), null);
});

test("recent periods go back by half-months", () => {
  const p = recentPeriods(new Date(2026, 2, 4, 10), 4);
  assert.deepEqual(p.map((x) => x.from), ["2026-03-01", "2026-02-16", "2026-02-01", "2026-01-16"]);
  assert.deepEqual(p.map((x) => x.to), ["2026-03-15", "2026-02-28", "2026-02-15", "2026-01-31"]);
  assert.deepEqual(recentPeriods(new Date(2026, 8, 30, 23, 59), 1), [{ from: "2026-09-16", to: "2026-09-30" }]);
});
