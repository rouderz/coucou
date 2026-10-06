// Coucou for AliExpress — the background service worker.
//
// Keeps the orders read from your AliExpress pages in this browser (chrome.storage.local), reads
// the pages still missing (an order's detail, its tracking) in one minimised window of its own,
// and tells Coucou about the packages through native messaging. Coucou answers with what to do:
// make a package's invoice (PDF), export everything (CSV for Excel / Sheets), or refresh. Files go
// to your Downloads folder, under Coucou/AliExpress.
//
// A separate extension from Coucou for WhaTicket (extensions/whaticket); both talk to the same
// native-messaging host, which lets either extension id in.

"use strict";

if (typeof importScripts === "function") importScripts("aliexpress-core.js");

const HOST = "fr.louisraille.coucou";

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
    chrome.action.setBadgeBackgroundColor({ color: "#FF4747" });
    chrome.action.setTitle({ title });
  } catch {
    // no action UI
  }
}

(function () {
  if (typeof chrome === "undefined" || !chrome.runtime || !chrome.storage) return;
  const A = self.CoucouAli;
  const ORIGIN = "https://www.aliexpress.com/";
  const KEY = "aliexpress";

  async function load() {
    const got = await chrome.storage.local.get(KEY);
    return got[KEY] || { orders: {}, numbers: {}, files: [] };
  }
  async function save(state) {
    await chrome.storage.local.set({ [KEY]: state });
  }

  // ── Pages read in the background ─────────────────────────────────────────

  let fetching = false;
  let waiting = null; // { tabId, resolve }

  function pageUrl(f) {
    return f.page === "detail"
      ? `${ORIGIN}p/order/detail.html?orderId=${f.id}`
      : `${ORIGIN}p/tracking/index.html?tradeOrderId=${f.id}`;
  }

  /** Reads the pages Coucou still needs, one at a time, in a minimised window closed at the end. */
  async function fetchMissing() {
    if (fetching) return;
    fetching = true;
    let win = null;
    try {
      for (let round = 0; round < 3; round++) {
        const state = await load();
        const todo = A.pendingFetches(state.orders, Date.now());
        if (!todo.length) break;
        for (const f of todo) {
          if (!win) win = await chrome.windows.create({ url: pageUrl(f), state: "minimized", focused: false });
          else await chrome.tabs.update(win.tabs[0].id, { url: pageUrl(f) });
          const tabId = win.tabs[0].id;
          const got = await new Promise((resolve) => {
            waiting = { tabId, resolve };
            setTimeout(() => resolve(null), 25_000);
          });
          waiting = null;
          if (!got) {
            // Nothing readable (page changed, signed out): don't ask again for six hours.
            const s = await load();
            const o = s.orders[f.id];
            if (o) {
              if (f.page === "detail") o.detailAt = Date.now();
              else o.trackedAt = Date.now();
              await save(s);
            }
          }
          await new Promise((r) => setTimeout(r, 1200)); // gentle with AliExpress
        }
      }
    } finally {
      if (win) chrome.windows.remove(win.id).catch(() => {});
      fetching = false;
      tellCoucou();
    }
  }

  // ── What the pages send ───────────────────────────────────────────────────

  async function receive(page, data, tabId) {
    const state = await load();
    const now = Date.now();
    const updates = page === "list" ? data || [] : data ? [data] : [];
    for (const u of updates) state.orders[u.id] = A.mergeOrder(state.orders[u.id], u, now);
    await save(state);
    if (waiting && waiting.tabId === tabId) waiting.resolve(true);
    if (page === "list") fetchMissing();
    tellCoucou();
  }

  // ── Coucou ────────────────────────────────────────────────────────────────

  let nextCheckAt = 0;

  async function tellCoucou() {
    const state = await load();
    const packages = A.packagesOf(state.orders);
    const reply = await toCoucou({
      kind: "aliexpress",
      orders: Object.keys(state.orders).length,
      packages: A.summary(packages, state.orders),
      syncing: fetching,
      files: state.files.slice(-10),
    });
    if (reply.unreachable) {
      badge(false, "Coucou for AliExpress — Coucou isn't running or isn't set up (Settings → AliExpress)");
      return;
    }
    badge(true, `Coucou for AliExpress — ${packages.length} packages`);
    nextCheckAt = Date.now() + (Number(reply.interval) || 60) * 1000;
    for (const cmd of reply.commands || []) await runCommand(cmd);
  }

  async function runCommand(cmd) {
    const state = await load();
    if (cmd.op === "sync") {
      fetchMissing();
      return;
    }
    const packages = A.packagesOf(state.orders);
    const date = new Date().toISOString().slice(0, 10);
    if (cmd.op === "invoice" && typeof cmd.tracking === "string") {
      const pkg = packages.find((p) => p.tracking.toUpperCase() === cmd.tracking.toUpperCase());
      if (!pkg) return;
      const { number, numbers } = A.invoiceNumber(state.numbers, pkg.tracking, date.slice(0, 4));
      state.numbers = numbers;
      const inv = A.invoiceOf(pkg, state.orders);
      const bytes = A.invoicePdf(inv, {
        buyer: cmd.buyer || {}, number, date, lang: cmd.lang === "es" ? "es" : "en", images: await pictures(inv.lines),
      });
      const name = `Coucou/AliExpress/${cmd.lang === "es" ? "Factura" : "Invoice"} ${number} ${safe(pkg.tracking)}.pdf`;
      await download(state, name, bytes, "application/pdf", { tracking: pkg.tracking, number });
    } else if (cmd.op === "csv") {
      const bytes = new TextEncoder().encode("﻿" + A.csv(packages, state.orders)); // BOM: Excel reads UTF-8
      await download(state, `Coucou/AliExpress/aliexpress-${date}.csv`, bytes, "text/csv", { csv: true });
    }
    await save(state);
  }

  // ── Product pictures for the invoice ──────────────────────────────────────

  const thumbs = new Map(); // address → { w, h, data } | null, for this worker's life

  /** A small JPEG of a product picture (at most 160 px), as the PDF wants it; null when it fails. */
  async function thumb(url) {
    if (thumbs.has(url)) return thumbs.get(url);
    let out = null;
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 10000);
      const res = await fetch(url, { credentials: "omit", signal: ctl.signal });
      clearTimeout(timer);
      if (res.ok) {
        const bmp = await createImageBitmap(await res.blob());
        const s = Math.min(1, 160 / Math.max(bmp.width, bmp.height));
        const w = Math.max(1, Math.round(bmp.width * s)), h = Math.max(1, Math.round(bmp.height * s));
        const canvas = new OffscreenCanvas(w, h);
        const ctx = canvas.getContext("2d");
        ctx.fillStyle = "#fff"; // transparent PNGs get a white background, not black
        ctx.fillRect(0, 0, w, h);
        ctx.drawImage(bmp, 0, 0, w, h);
        const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.85 });
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let data = "";
        for (let i = 0; i < bytes.length; i += 0x8000) data += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
        out = { w, h, data };
      }
    } catch {
      out = null; // no picture: the invoice shows a plain square instead
    }
    thumbs.set(url, out);
    return out;
  }

  async function pictures(lines) {
    const images = {};
    for (const l of lines.slice(0, 60)) {
      if (l.image && !(l.image in images)) images[l.image] = await thumb(l.image);
    }
    return images;
  }

  function safe(s) {
    return String(s).replace(/[^A-Za-z0-9_-]/g, "");
  }

  async function download(state, filename, bytes, mime, meta) {
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    const id = await chrome.downloads.download({ url: `data:${mime};base64,${btoa(bin)}`, filename, saveAs: false, conflictAction: "overwrite" });
    // Where it landed (Coucou shows it and opens it).
    await new Promise((r) => setTimeout(r, 800));
    const [item] = await chrome.downloads.search({ id });
    state.files.push({ ...meta, path: item ? item.filename : filename, at: Date.now() });
    state.files = state.files.slice(-30);
  }

  // ── Wiring ────────────────────────────────────────────────────────────────

  chrome.runtime.onMessage.addListener((message, sender) => {
    if (sender.id !== chrome.runtime.id || !sender.url || !sender.url.startsWith(ORIGIN)) return false;
    if (!message || message.type !== "aliexpress") return false;
    receive(message.page, message.data, sender.tab && sender.tab.id);
    return false;
  });

  // Coucou's buttons (invoice, export, refresh) are picked up at the next check-in.
  chrome.alarms.create("coucou-aliexpress", { periodInMinutes: 0.5 });
  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name !== "coucou-aliexpress" || Date.now() < nextCheckAt) return;
    load().then((s) => { if (Object.keys(s.orders).length) tellCoucou(); });
  });
})();
