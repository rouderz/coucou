// node --test extensions/whaticket/background.test.js
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { jwtPayload, userIdOf, ticketsPath, ticketView, validId, listOf, run, CHANNELS } = require("./background.js");

const b64url = (s) => Buffer.from(s).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

test("reads who is signed in from the session token", () => {
  const token = `x.${b64url(JSON.stringify({ id: "u-1", name: "Ana Pérez" }))}.sig`;
  assert.deepEqual(jwtPayload(token), { id: "u-1", name: "Ana Pérez" });
  assert.equal(userIdOf(jwtPayload(token)), "u-1");
  assert.equal(userIdOf({ sub: 7 }), "7");
  assert.deepEqual(jwtPayload("not a token"), {});
  assert.equal(userIdOf({}), "");
});

test("asks for tickets like the web app's inbox", () => {
  const url = new URL("https://x" + ticketsPath("open", ["u-1"]));
  assert.equal(url.pathname, "/tickets");
  assert.equal(url.searchParams.get("status"), '["open"]');
  assert.equal(url.searchParams.get("usersIds"), '["u-1"]');
  assert.equal(url.searchParams.get("queueIds"), "[]");
  assert.deepEqual(JSON.parse(url.searchParams.get("channels")), CHANNELS);
  assert.ok(!CHANNELS.includes("INTERNAL"));
});

test("keeps only what Coucou shows", () => {
  const queues = [{ id: "q-1", name: "Soporte", color: "#0af" }];
  const v = ticketView({ id: "t-1", status: "pending", queueId: "q-1", userId: null, unreadMessages: 3,
    lastMessage: "Hola", contact: { name: "", number: "54911" }, metadata: { aiHandling: true }, secret: "x" }, queues);
  assert.deepEqual(v, { id: "t-1", name: "54911", lastMessage: "Hola", unread: 3, queueId: "q-1", queue: "Soporte",
    queueColor: "#0af", updatedAt: "", status: "pending", userId: null, isGroup: false, aiHandling: true });
});

test("only plain ids are ever sent back to WhaTicket", () => {
  assert.ok(validId("6b1c0e2a-1d2f-4c1b-9a77-0f3c2b1a9e10"));
  assert.ok(validId("42"));
  assert.ok(!validId("../users"));
  assert.ok(!validId("a/b"));
  assert.ok(!validId(42));
  assert.deepEqual(listOf({ tickets: [1] }, "tickets"), [1]);
  assert.deepEqual(listOf([2], "tickets"), [2]);
  assert.deepEqual(listOf(null, "tickets"), []);
});

test("accepts only tickets still waiting, with the web app's own call", async () => {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push([url, init.method, init.body]);
    return { ok: true, status: 200, json: async () => ({}) };
  };
  const results = await run("tok", [
    { op: "accept", id: "t-1" },
    { op: "accept", id: "t-2" },
    { op: "accept", id: "../x" },
    { op: "delete", id: "t-1" },
  ], new Set(["t-1", "../x"]));
  assert.deepEqual(calls, [["https://api.whaticket.com/tickets/t-1/assign", "POST", '{"shouldStartNewConversation":false}']]);
  assert.deepEqual(results.map((r) => [r.id, r.ok]), [["t-1", true], ["t-2", false]]);
});

test("a 403 is a missing permission, not an expired session", async () => {
  globalThis.fetch = async () => ({ ok: false, status: 403, json: async () => ({}) });
  const [r] = await run("tok", [{ op: "accept", id: "t-1" }], new Set(["t-1"]));
  assert.equal(r.ok, false);
  assert.notEqual(r.error, "session");
});
