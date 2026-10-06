import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAliCommand } from "./aliexpressCommand.ts";

test("aliexpress chat commands", () => {
  assert.deepEqual(parseAliCommand("aliexpress"), { op: "sync" });
  assert.deepEqual(parseAliCommand("/AliExpress pedidos"), { op: "sync" });
  assert.deepEqual(parseAliCommand("aliexpress facturas"), { op: "invoices" });
  assert.deepEqual(parseAliCommand("aliexpress invoices."), { op: "invoices" });
  assert.deepEqual(parseAliCommand("aliexpress factura lp00123456789"), { op: "invoice", tracking: "LP00123456789" });
  assert.deepEqual(parseAliCommand("aliexpress csv"), { op: "csv" });
});

test("ordinary questions still go to the chat", () => {
  assert.equal(parseAliCommand("¿qué pedidos de aliexpress tengo?"), null);
  assert.equal(parseAliCommand("aliexpress is slow today"), null);
  assert.equal(parseAliCommand("ali facturas"), null);
  assert.equal(parseAliCommand("facturas"), null);
});
