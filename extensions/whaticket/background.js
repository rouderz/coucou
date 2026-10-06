// Coucou for WhaTicket — background service worker.
//
// While a whaticket.com tab is open, content.js hands us the page's own session
// token every few seconds. We read the queue with it (the same calls the web app
// makes, with the same permissions as you), send a summary to Coucou through
// native messaging, and run what Coucou answers: "accept ticket X" is the same
// POST /tickets/{id}/assign the Accept button sends.
//
// We never refresh or store the session ourselves: whaticket.com renews it in the
// tab, and a second renewal from here would sign the tab out. When the token has
// expired we just say so and wait for the tab to renew it.

"use strict";

const HOST = "fr.louisraille.coucou";
const API = "https://api.whaticket.com";
// Every channel the web app lists in its inbox (it leaves out INTERNAL chats).
const CHANNELS = ["FACEBOOK", "INSTAGRAM", "WHATSAPP", "WIDGET", "WABA", "WABA-COEX", "TIKTOK", "TELEGRAM", "SANDBOX"];
const QUEUES_EVERY_MS = 10 * 60 * 1000;
// Coucou shows a handful; this keeps one check-in well under native messaging's limits.
const MAX_TICKETS = 200;

// ── Pure helpers (tested in background.test.js) ──────────────────────────────

/** The JWT's payload (who is signed in), or {} when it can't be read. */
function jwtPayload(token) {
  try {
    const part = String(token).split(".")[1];
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    const text = decodeURIComponent(
      Array.from(atob(b64), (c) => "%" + c.charCodeAt(0).toString(16).padStart(2, "0")).join(""),
    );
    return JSON.parse(text) || {};
  } catch {
    return {};
  }
}

/** The signed-in user's id, whichever claim carries it. */
function userIdOf(claims) {
  const id = claims.id ?? claims.userId ?? claims.user_id ?? claims.sub;
  return id == null ? "" : String(id);
}

/** GET /tickets with the parameters the web app's inbox sends. */
function ticketsPath(status, usersIds = []) {
  const p = new URLSearchParams({
    status: JSON.stringify([status]),
    queueIds: "[]",
    connectionsIds: "[]",
    tagsIds: "[]",
    usersIds: JSON.stringify(usersIds),
    channels: JSON.stringify(CHANNELS),
  });
  return `/tickets?${p.toString()}`;
}

/** The few fields Coucou shows, from one ticket of the API. */
function ticketView(t, queues = []) {
  const contact = t.contact || {};
  const queueId = t.queueId == null ? null : String(t.queueId);
  const queue = t.queue || queues.find((q) => String(q.id) === queueId) || null;
  return {
    id: String(t.id),
    name: contact.name || contact.number || "?",
    lastMessage: typeof t.lastMessage === "string" ? t.lastMessage.slice(0, 300) : "",
    unread: Number(t.unreadMessages) || 0,
    queueId,
    queue: (queue && queue.name) || "",
    queueColor: (queue && queue.color) || "",
    updatedAt: t.updatedAt || "",
    status: t.status || "",
    userId: t.userId == null ? null : String(t.userId),
    isGroup: !!t.isGroup,
    aiHandling: !!(t.metadata && t.metadata.aiHandling),
  };
}

/** Ticket ids are UUIDs (or numbers): anything else is not ours to send anywhere. */
function validId(id) {
  return typeof id === "string" && /^[A-Za-z0-9-]{1,64}$/.test(id);
}

function listOf(json, key) {
  if (Array.isArray(json)) return json;
  return (json && Array.isArray(json[key]) && json[key]) || [];
}

// ── WhaTicket calls ───────────────────────────────────────────────────────────

class SessionError extends Error {}

async function api(token, method, path, body) {
  const response = await fetch(API + path, {
    method,
    credentials: "include",
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  // 401 only: a 403 is a missing permission (e.g. queues:view), not a dead session.
  if (response.status === 401) throw new SessionError("session");
  if (response.status === 403) throw new Error("Your WhaTicket profile isn't allowed to do that (403).");
  if (!response.ok) throw new Error(`WhaTicket answered ${response.status}`);
  if (response.status === 204) return null;
  return response.json().catch(() => null);
}

let queues = { at: 0, list: [] };

async function snapshot(token) {
  if (!token) return { error: "signed_out" };
  const claims = jwtPayload(token);
  const userId = userIdOf(claims);
  if (Date.now() - queues.at > QUEUES_EVERY_MS) {
    try {
      queues = { at: Date.now(), list: listOf(await api(token, "GET", "/queues"), "queues") };
    } catch (e) {
      if (e instanceof SessionError) throw e;
      queues = { at: Date.now(), list: [] }; // a user without queues:view still gets tickets
    }
  }
  const named = queues.list.map((q) => ({ id: String(q.id), name: q.name || "", color: q.color || "" }));
  const pending = listOf(await api(token, "GET", ticketsPath("pending")), "tickets");
  const open = userId ? listOf(await api(token, "GET", ticketsPath("open", [userId])), "tickets") : [];
  return {
    user: { id: userId, name: claims.name || claims.username || "" },
    queues: named,
    pending: pending.filter((t) => t.status !== "open").slice(0, MAX_TICKETS).map((t) => ticketView(t, named)),
    mine: open.filter((t) => String(t.userId) === userId).slice(0, MAX_TICKETS).map((t) => ticketView(t, named)),
  };
}

/**
 * Runs Coucou's commands. Only tickets still waiting in the queue we just read are
 * accepted: a click can wait a few seconds, and by then a colleague may have it.
 */
async function run(token, commands, pendingIds) {
  const results = [];
  for (const cmd of commands || []) {
    if (cmd.op !== "accept" || !validId(cmd.id) || !token) continue;
    if (!pendingIds.has(cmd.id)) {
      results.push({ op: "accept", id: cmd.id, ok: false, error: "Someone already took that ticket." });
      continue;
    }
    try {
      await api(token, "POST", `/tickets/${cmd.id}/assign`, { shouldStartNewConversation: false });
      results.push({ op: "accept", id: cmd.id, ok: true });
    } catch (e) {
      results.push({ op: "accept", id: cmd.id, ok: false, error: e instanceof SessionError ? "session" : String(e.message || e) });
    }
  }
  return results;
}

// ── Coucou (native messaging) ─────────────────────────────────────────────────

function toCoucou(message) {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
        if (chrome.runtime.lastError) resolve({ unreachable: chrome.runtime.lastError.message });
        else resolve(reply || {});
      });
    } catch (e) {
      resolve({ unreachable: String(e) });
    }
  });
}

function badge(ok, title) {
  try {
    chrome.action.setBadgeText({ text: ok ? "" : "!" });
    chrome.action.setBadgeBackgroundColor({ color: "#F4505E" });
    chrome.action.setTitle({ title });
  } catch {
    // no action UI (tests)
  }
}

let busy = false;

let lastTokenAt = 0;

async function tick(token) {
  if (busy) return { interval: 5 };
  // Several whaticket.com tabs: one without a session (the login page, a stale window)
  // stays quiet while another tab is signed in, instead of reporting "signed out".
  if (token) lastTokenAt = Date.now();
  else if (Date.now() - lastTokenAt < 60_000) return { interval: 30 };
  busy = true;
  try {
    let data;
    try {
      data = await snapshot(token);
    } catch (e) {
      data = { error: e instanceof SessionError ? "session" : String(e.message || e) };
    }
    let reply = await toCoucou({ kind: "snapshot", ...data });
    if (reply.unreachable) {
      badge(false, "Coucou isn't answering: open Coucou and set up the browser extension in Settings → WhaTicket.");
      return { interval: 30 };
    }
    // Coucou's answer: tickets to accept now (a click, or auto-accept).
    const pendingIds = new Set((data.pending || []).map((t) => t.id));
    const results = await run(token, reply.commands, pendingIds);
    if (results.length) reply = await toCoucou({ kind: "results", results });
    badge(!data.error, data.error === "session"
      ? "whaticket.com needs you to sign in again (or use the tab once)."
      : data.error ? `WhaTicket: ${data.error}` : "Connected to Coucou");
    return { interval: Number(reply.interval) || 15 };
  } finally {
    busy = false;
  }
}

if (typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.onMessage) {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    // Only our own content script, on whaticket.com.
    if (sender.id !== chrome.runtime.id || !sender.url || !sender.url.startsWith("https://app.whaticket.com/")) return false;
    if (!message || message.type !== "tick") return false;
    tick(typeof message.token === "string" ? message.token : null).then(sendResponse, () => sendResponse({ interval: 30 }));
    return true; // answer asynchronously
  });
}

// AliExpress packages and invoices (aliexpress-core.js, aliexpress-bg.js).
if (typeof importScripts === "function") importScripts("aliexpress-core.js", "aliexpress-bg.js");

if (typeof module !== "undefined") {
  module.exports = { jwtPayload, userIdOf, ticketsPath, ticketView, validId, listOf, run, CHANNELS };
}
