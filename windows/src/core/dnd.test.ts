import { test } from "node:test";
import assert from "node:assert/strict";
import { dndActive, dndStatus, FOREVER, tomorrowMorning } from "./dnd.ts";

test("do not disturb: on, off and how it reads", () => {
  const now = new Date(2026, 9, 2, 17, 0).getTime();
  assert.ok(!dndActive(null, now));
  assert.ok(!dndActive(now - 1, now));
  assert.ok(dndActive(now + 60_000, now));
  assert.equal(dndStatus(now + 90 * 60_000, now), "On until 18:30");
  assert.equal(dndStatus(FOREVER, now), "On until you turn it off");
  assert.equal(dndStatus(tomorrowMorning(new Date(now)), now), "On until tomorrow 09:00");
  assert.equal(dndStatus(null, now), null);
});
