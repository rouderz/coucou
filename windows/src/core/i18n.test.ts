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
  _test.setLang("en");
  assert.equal(t("Allow"), "Allow");
});
