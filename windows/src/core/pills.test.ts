import { test } from "node:test";
import assert from "node:assert/strict";
import { visiblePillIds } from "./pills.ts";

const ids = ["a", "b", "c", "d", "e", "f"];

test("few pills are all shown", () => {
  assert.deepEqual(visiblePillIds(["a", "b", "c"], { offset: 7 }), ["a", "b", "c"]);
  assert.deepEqual(visiblePillIds(["a", "b", "c", "d"], { offset: 3 }), ["a", "b", "c", "d"]);
});

test("rotation advances and wraps", () => {
  assert.deepEqual(visiblePillIds(ids, { offset: 0 }), ["a", "b", "c", "d"]);
  assert.deepEqual(visiblePillIds(ids, { offset: 1 }), ["b", "c", "d", "e"]);
  assert.deepEqual(visiblePillIds(ids, { offset: 3 }), ["a", "d", "e", "f"]);
  assert.deepEqual(visiblePillIds(ids, { offset: 6 }), ["a", "b", "c", "d"]);
});

test("pinned pills never rotate out", () => {
  for (let offset = 0; offset < 12; offset++) {
    assert.ok(visiblePillIds(ids, { pinned: ["f"], offset }).includes("f"));
  }
  assert.deepEqual(visiblePillIds(ids, { pinned: ["f"], offset: 0 }), ["a", "b", "c", "f"]);
});

test("news jumps into view", () => {
  for (let offset = 0; offset < 12; offset++) {
    assert.ok(visiblePillIds(ids, { news: ["e"], offset }).includes("e"));
  }
});

test("pinned win over news and the limit holds", () => {
  assert.deepEqual(
    visiblePillIds(ids, { pinned: ["a", "b", "c", "d", "e"], news: ["f"], offset: 2 }),
    ["a", "b", "c", "d"],
  );
  assert.equal(visiblePillIds(ids, { news: ids, offset: 0 }).length, 4);
});

test("negative offset and empty input", () => {
  assert.equal(visiblePillIds(ids, { offset: -1 }).length, 4);
  assert.deepEqual(visiblePillIds([], { offset: 3 }), []);
});
