// Coucou for AliExpress — runs on your AliExpress order pages, with your own session.
//
// Reads what the page shows (nothing else): the order list, an order's detail (products, their
// pictures, amounts and when it was placed) and an order's tracking page (carrier, tracking number, what's in the box). It hands
// that to the extension's background, which keeps it in this browser and tells Coucou. Nothing is
// clicked, bought or changed.

"use strict";

(function () {
  const A = self.CoucouAli;
  const text = (el) => (el ? el.innerText.trim() : "");
  const all = (sel, root = document) => [...root.querySelectorAll(sel)];
  const byPrefix = (prefix, root = document) => all(`[class*="${prefix}"]`, root);

  /**
   * The product picture next to a line: an <img> or a background-image in the line's own block
   * (never climbing into a block that holds several products).
   */
  function imageOf(el, lineSel) {
    let n = el;
    for (let i = 0; n && i < 4; i++, n = n.parentElement) {
      if (i > 0 && n.querySelectorAll(lineSel).length > 1) break;
      for (const img of n.querySelectorAll("img")) {
        const u = A.imageUrl(img.currentSrc || img.src || img.getAttribute("data-src"));
        if (u) return u;
      }
      for (const bg of n.querySelectorAll('[style*="background-image"]')) {
        const u = A.imageUrl(bg.style.backgroundImage);
        if (u) return u;
      }
    }
    return null;
  }

  /** When the order was placed, from the detail page's info block ("Order placed on: …"). */
  function orderTime() {
    const lines = document.body.innerText.split("\n").map((s) => s.trim()).filter(Boolean);
    let dateOnly = null;
    for (let i = 0; i < lines.length; i++) {
      if (!/order (placed|time|date)|placed on|pedido realizado|realizado el|hora del pedido|fecha del pedido/i.test(lines[i])) continue;
      const t = A.dateTime(lines[i]) || A.dateTime(lines[i + 1] || "");
      if (t && t.length > 10) return t;
      dateOnly = dateOnly || t;
    }
    return dateOnly;
  }

  function readList() {
    return all(".order-item").map((o) => {
      const link = o.querySelector('a[href*="orderId="]');
      const id = A.orderIdFrom(link && link.href);
      if (!id) return null;
      const lines = all(".order-item-content-body", o).map((body) => {
        const pq = A.priceQty(body.innerText) || { price: 0, qty: 1, currency: "USD" };
        return { title: text(body.querySelector(".order-item-content-info-name")), sku: text(body.querySelector(".order-item-content-info-sku")),
          price: pq.price, qty: pq.qty, currency: pq.currency, image: imageOf(body, ".order-item-content-body") };
      }).filter((l) => l.title);
      return {
        id, source: "list",
        status: text(o.querySelector(".order-item-header-status-text")),
        date: A.isoDate(text(o.querySelector(".order-item-header-right-info"))),
        store: text(o.querySelector(".order-item-store-name")),
        currency: lines[0] ? lines[0].currency : undefined,
        total: o.querySelector(".order-item-content-opt-price-total") ? A.amount(text(o.querySelector(".order-item-content-opt-price-total"))) : undefined,
        lines,
      };
    }).filter(Boolean);
  }

  function readDetail(id) {
    const items = all(".order-detail-item-content-info");
    if (!items.length) return null;
    const lines = items.map((el) => {
      const parts = el.innerText.split("\n").map((s) => s.trim()).filter(Boolean);
      const pq = A.priceQty(el.innerText) || { price: 0, qty: 1, currency: "USD" };
      // Title first; the variant is the short line between the title and the price.
      const priceAt = parts.findIndex((p) => A.priceQty(p));
      const sku = priceAt > 1 ? parts.slice(1, priceAt).join(" ") : "";
      return { title: parts[0] || "", sku, price: pq.price, qty: pq.qty, currency: pq.currency,
        image: imageOf(el, ".order-detail-item-content-info") };
    }).filter((l) => l.title);
    const rows = all(".order-price-item").map((el) => {
      const parts = el.innerText.split("\n").map((s) => s.trim()).filter(Boolean);
      return [parts[0] || "", parts[parts.length - 1] || ""];
    });
    const prices = A.priceBlock(rows);
    return { id, source: "detail", lines, currency: lines[0] ? lines[0].currency : undefined, ...prices, time: orderTime() || undefined,
      status: text(document.querySelector(".order-status-content, .order-status")).split("\n")[0] || undefined,
      store: text(document.querySelector(".order-detail-item-store")).split("\n")[0] || undefined };
  }

  function readTracking(id) {
    const numbers = byPrefix("logistic-info-v2--mailNoValue").map(text).filter(Boolean);
    if (!numbers.length) return null;
    const carriers = byPrefix("logistic-info-v2--carrierValue").map(text);
    const titles = byPrefix("logistic-info-v2--nodeTitle").map(text);
    const descs = byPrefix("logistic-info-v2--nodeDesc").map(text);
    const times = byPrefix("logistic-info-v2--nodeTime").map(text);
    const packages = numbers.map((tracking, i) => ({
      tracking: tracking.replace(/\s+/g, ""),
      carrier: (carriers[i] || carriers[0] || "").split("\n")[0],
      status: i === 0 ? titles[0] || "" : "",
      lastEvent: i === 0 ? descs[0] || "" : "",
      lastTime: i === 0 ? times[0] || "" : "",
    }));
    return { id, source: "tracking", packages };
  }

  /** Waits for the page's own scripts to draw what we read (they load it after the HTML). */
  function whenReady(read, tries = 30) {
    return new Promise((resolve) => {
      const attempt = (n) => {
        const out = read();
        if (out || n <= 0) return resolve(out);
        setTimeout(() => attempt(n - 1), 500);
      };
      attempt(tries);
    });
  }

  async function run() {
    const url = location.href;
    let page = null, data = null;
    if (/\/p\/order\/index\.html/.test(url)) {
      page = "list";
      data = await whenReady(() => { const l = readList(); return l.length ? l : null; });
    } else if (/\/p\/order\/detail\.html/.test(url)) {
      page = "detail";
      const id = A.orderIdFrom(url);
      data = id && (await whenReady(() => readDetail(id)));
    } else if (/\/p\/tracking\//.test(url)) {
      page = "tracking";
      const id = A.orderIdFrom(url);
      data = id && (await whenReady(() => readTracking(id)));
    }
    if (!page) return;
    try {
      await chrome.runtime.sendMessage({ type: "aliexpress", page, data: data || null });
    } catch {
      // The extension was reloaded: this page's script is orphaned.
    }
  }

  run();
  // The order list loads more orders as you scroll ("View more"): read it again when it grows.
  if (/\/p\/order\/index\.html/.test(location.href)) {
    let count = 0;
    setInterval(() => {
      const n = document.querySelectorAll(".order-item").length;
      if (n > count) { count = n; run(); }
    }, 4000);
  }
})();
