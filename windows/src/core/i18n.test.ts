import { test } from "node:test";
import assert from "node:assert/strict";
import { _test, resolveLanguage, t } from "./i18n.ts";

test("language: system or chosen", () => {
  assert.equal(resolveLanguage("system", "es-MX"), "es");
  assert.equal(resolveLanguage("system", "en-US"), "en");
  assert.equal(resolveLanguage("en", "es-ES"), "en");
  assert.equal(resolveLanguage("es", "en-US"), "es");
});

test("spanish: exact, patterns, pieces; the rest untouched", () => {
  _test.setLang("es");
  assert.equal(t("Allow"), "Permitir");
  assert.equal(t("  Deny "), "  Denegar ");
  assert.equal(t("High risk · deletes files recursively"), "Riesgo alto · borra archivos de forma recursiva");
  assert.equal(t("Run · npm test"), "Ejecuta · npm test");
  assert.equal(t("+2 waiting"), "+2 en espera");
  assert.equal(t("Key saved in the Windows Credential Manager."), "Clave guardada en el Administrador de credenciales de Windows.");
  assert.equal(t("Auto-close · 15s"), "Cierre automático · 15 s");
  assert.equal(t("fix the login bug"), "fix the login bug");
  assert.equal(t("Standup in 12 min"), "Standup en 12 min");
  assert.equal(t("Review in 1 h 5 min"), "Review en 1 h 5 min");
  assert.equal(t("Now: Standup (until 10:15)"), "Ahora: Standup (hasta las 10:15)");
  assert.equal(t("Block done! Break, 5 min?"), "¡Bloque terminado! ¿Descanso de 5 min?");
  assert.equal(t("Long break · paused"), "Descanso largo · en pausa");
  assert.equal(t("Focus: 50 min on SHO-475. Do not disturb is on until the end of the block."),
    "Concentración: 50 min en SHO-475. No molestar está activado hasta el final del bloque.");
  _test.setLang("en");
  assert.equal(t("Allow"), "Allow");
});

test("voice: speaks plain words", async () => {
  // speakable() lives in voice.ts, which needs the DOM; the same rules here.
  const speakable = (text: string) => text.replace(/```[\s\S]*?```/g, " ").replace(/https?:\/\/\S+/g, " ")
    .replace(/[*_#`>]+/g, "").replace(/\s+/g, " ").trim();
  assert.equal(speakable("**Done.** See https://x.dev/a\n```js\nx()\n```"), "Done. See");
});
