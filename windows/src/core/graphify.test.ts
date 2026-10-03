import { test } from "node:test";
import assert from "node:assert/strict";
import {
  builtAtCommitArgs, changedFilesArgs, cliCandidates, cliStatus, compareVersions, graphStatus, parseChangedFiles,
  parseGraphCounts, parseStamp, parseVersion, stampText, trimQueryOutput,
} from "./graphify.ts";

test("graphify: CLI candidates keep PATH first, add uv and ~/.local/bin, no duplicates", () => {
  const list = cliCandidates("linux", "/home/u", { PATH: "/usr/bin::/home/u/.local/bin", UV_TOOL_BIN_DIR: "/opt/uv" });
  assert.deepEqual(list, ["/usr/bin/graphify", "/home/u/.local/bin/graphify", "/opt/uv/graphify"]);
  const win = cliCandidates("windows", "C:\\Users\\u", { Path: "C:\\Tools;c:\\tools" });
  assert.equal(win[0], "C:\\Tools\\graphify.exe");
  assert.equal(win.filter((p) => p.toLowerCase().startsWith("c:\\tools\\")).length, 3);
  assert.ok(win.includes("C:\\Users\\u\\.local\\bin\\graphify.exe"));
});

test("graphify: versions", () => {
  assert.deepEqual(parseVersion("graphify 0.4.2\n"), [0, 4, 2]);
  assert.deepEqual(parseVersion("v1.2"), [1, 2, 0]);
  assert.equal(parseVersion("command not found"), null);
  assert.equal(compareVersions([0, 4, 2], [0, 10, 0]), -1);
  assert.equal(compareVersions([1, 0, 0], [1, 0, 0]), 0);
});

test("graphify: CLI status", () => {
  assert.deepEqual(cliStatus(null, null), { state: "missing" });
  assert.equal(cliStatus("/x/graphify", "oops").state, "unknown");
  assert.equal(cliStatus("/x/graphify", null).state, "unknown");
  assert.equal(cliStatus("/x/graphify", "graphify 0.3.0", [0, 4, 0]).state, "old");
  assert.equal(cliStatus("/x/graphify", "graphify 0.4.0", [0, 4, 0]).state, "ok");
});

test("graphify: stamp file round trip and bad input", () => {
  assert.deepEqual(parseStamp(stampText("abc1234", 99)), { commit: "abc1234", builtAt: 99 });
  assert.equal(parseStamp("{"), null);
  assert.equal(parseStamp('{"commit":"--output=/etc/x"}'), null);
});

test("graphify: graph.json counts are best effort", () => {
  assert.deepEqual(parseGraphCounts('{"nodes":[1,2,3],"edges":[1]}'), { nodes: 3, edges: 1 });
  assert.deepEqual(parseGraphCounts('{"nodes":[1],"links":[1,2]}'), { nodes: 1, edges: 2 });
  assert.equal(parseGraphCounts("[]"), null);
  assert.equal(parseGraphCounts("nope"), null);
});

test("graphify: git arguments reject anything that is not a commit id", () => {
  assert.deepEqual(changedFilesArgs("abc1234"), ["diff", "--name-only", "abc1234..HEAD"]);
  assert.equal(changedFilesArgs("--help"), null);
  assert.deepEqual(builtAtCommitArgs(1700000000.9), ["rev-list", "-1", "--before=1700000000", "HEAD"]);
});

test("graphify: stale detection ignores graphify-out and says what changed", () => {
  const changed = parseChangedFiles("src\\a.ts\nsrc/b.ts\ngraphify-out/graph.json\n\ngraphify-out\n");
  assert.deepEqual(changed, ["src/a.ts", "src/b.ts"]);
  assert.deepEqual(graphStatus(true, changed), { state: "stale", changed: 2, sample: ["src/a.ts", "src/b.ts"] });
  assert.deepEqual(graphStatus(true, parseChangedFiles("graphify-out/graph.json\n")), { state: "fresh" });
  assert.deepEqual(graphStatus(true, null), { state: "unknown" });
  assert.deepEqual(graphStatus(false, []), { state: "none" });
  const many = Array.from({ length: 9 }, (_, i) => `f${i}`);
  const s = graphStatus(true, many, 3);
  assert.equal(s.state === "stale" && s.sample.length, 3);
});

test("graphify: query output is cleaned and capped at a line", () => {
  assert.equal(trimQueryOutput("\u001b[1mNode\u001b[0m: A\r\n  --> B\r\n"), "Node: A\n  --> B");
  const big = Array.from({ length: 200 }, (_, i) => `  --> Node${i} [uses] [INFERRED]`).join("\n");
  const out = trimQueryOutput(big, 500);
  assert.ok(Array.from(out).length <= 500);
  assert.match(out, /\n… \d+ more lines left out \(capped at 500 characters\)$/);
  assert.ok(out.startsWith("--> Node0 "));
  const body = out.slice(0, out.lastIndexOf("\n…"));
  assert.ok(body.split("\n").every((l) => l.endsWith("[INFERRED]")));
  const one = trimQueryOutput("x".repeat(1000), 100);
  assert.equal(Array.from(one).length, 100);
  assert.ok(one.endsWith("…"));
  assert.equal(trimQueryOutput("short", 100), "short");
});
