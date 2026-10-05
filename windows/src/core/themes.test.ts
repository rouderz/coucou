import { test } from "node:test";
import assert from "node:assert/strict";
import { THEMES, DARK, LIGHT, contrast, palette, themeVars } from "./themes.ts";

test("Dark is the original look: no token is overridden", () => {
  assert.deepEqual(themeVars(DARK), {});
});

test("every theme defines every token and is readable", () => {
  const keys = Object.keys(themeVars(LIGHT)).sort();
  for (const t of THEMES) {
    if (t.id !== "dark") assert.deepEqual(Object.keys(themeVars(t)).sort(), keys, t.id);
    assert.ok(contrast(t.ink, t.card) >= 7, `${t.id} ink`);
    assert.ok(contrast(t.dim, t.card) >= 3, `${t.id} dim`);
    assert.ok(contrast(t.dim3, t.card) >= 2, `${t.id} dim3`);
  }
});

test("System follows the OS, unknown ids fall back to Dark", () => {
  assert.equal(palette("system", true).id, "dark");
  assert.equal(palette("system", false).id, "light");
  assert.equal(palette("nope", false).id, "dark");
  assert.equal(palette(undefined, false).id, "dark");
});
