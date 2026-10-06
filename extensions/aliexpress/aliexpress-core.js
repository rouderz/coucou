// Coucou for AliExpress — the pure part, shared by the content script (aliexpress.js), the
// background worker (background.js) and the tests (aliexpress.test.js).
//
// AliExpress splits one checkout into one order per store, then often ships several orders in a
// single box with one tracking number. Here the orders read from the user's own pages are grouped
// by that tracking number into packages, and one invoice (PDF) and one CSV row set are made per
// package.
//
// The invoice is the buyer's own document built from their orders. It says so, lists the
// AliExpress order numbers it comes from, and never imitates an AliExpress-issued invoice.

"use strict";

(function (root) {
  // ── Parsing the text of AliExpress pages ──────────────────────────────────

  /** "$17.22 x1", "US $2.39x3", "€ 1,234.50 x 2" → { currency, price, qty }; null when absent. */
  function priceQty(text) {
    const m = /(US\s?\$|\$|€|£|R\$)\s?([\d.,]+)\s*[x×]\s*(\d+)/.exec(String(text));
    if (!m) return null;
    return { currency: m[1].includes("€") ? "EUR" : m[1].includes("£") ? "GBP" : m[1].includes("R$") ? "BRL" : "USD", price: amount(m[2]), qty: Number(m[3]) };
  }

  /** "$1,234.56" / "1.234,56" / "12.68" → 12.68 (two decimals). */
  function amount(text) {
    const s = String(text).replace(/[^\d.,]/g, "");
    if (!s) return 0;
    const lastDot = s.lastIndexOf("."), lastComma = s.lastIndexOf(",");
    const dec = Math.max(lastDot, lastComma);
    // A separator followed by exactly 1-2 digits at the end is the decimal one.
    const isDecimal = dec >= 0 && s.length - dec - 1 <= 2;
    const whole = (isDecimal ? s.slice(0, dec) : s).replace(/[.,]/g, "");
    const frac = isDecimal ? s.slice(dec + 1) : "";
    return Math.round(Number(`${whole || "0"}.${frac || "0"}`) * 100) / 100;
  }

  /** The order id in a link like ".../order/detail.html?orderId=8214937669763641". */
  function orderIdFrom(href) {
    const m = /[?&](?:orderId|tradeOrderId)=(\d{6,24})/.exec(String(href));
    return m ? m[1] : null;
  }

  /** "Date: Sep 21, 2026 | Ref. Number: 8214…" → "2026-09-21" (null when unreadable). */
  function isoDate(text) {
    const m = /([A-Z][a-z]{2,8})\.? (\d{1,2}), (\d{4})/.exec(String(text));
    if (!m) return null;
    const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    const mo = months.indexOf(m[1].slice(0, 3).toLowerCase());
    if (mo < 0) return null;
    return `${m[3]}-${String(mo + 1).padStart(2, "0")}-${String(Number(m[2])).padStart(2, "0")}`;
  }

  /** The order's price block: [["Subtotal","$5.61"],["Shipping","$7.07"],["Total","$12.68"]] → amounts. */
  function priceBlock(rows) {
    const out = { subtotal: null, shipping: null, discount: null, total: null };
    for (const [label, value] of rows) {
      const l = String(label).toLowerCase();
      const v = amount(value);
      if (/sub\s?total/.test(l)) out.subtotal = v;
      else if (/^total|total$/.test(l.trim())) out.total = v;
      else if (/ship|env[ií]o|deliver/.test(l)) out.shipping = (out.shipping ?? 0) + v;
      else if (/discount|descuento|coupon|cup[oó]n|saving/.test(l)) out.discount = (out.discount ?? 0) + v;
    }
    return out;
  }

  // ── The store of orders ───────────────────────────────────────────────────

  /**
   * Merges what a page told us about an order into the stored record. Lines from the detail page
   * (exact) win over the list's (summary); packages from the tracking page replace older ones.
   */
  function mergeOrder(stored, update, now) {
    const o = { ...(stored || { id: update.id, lines: [], packages: [] }) };
    for (const k of ["date", "status", "store", "currency", "subtotal", "shipping", "discount", "total"]) {
      if (update[k] !== undefined && update[k] !== null && update[k] !== "") o[k] = update[k];
    }
    if (update.lines && update.lines.length && (update.source === "detail" || !o.linesFromDetail)) {
      o.lines = update.lines;
      if (update.source === "detail") o.linesFromDetail = true;
    }
    if (update.source === "detail") o.detailAt = now;
    if (update.packages) {
      o.packages = update.packages;
      o.trackedAt = now;
    }
    o.updatedAt = now;
    return o;
  }

  const DONE = /complet|finish|closed|cancel|refund|finalizad|cerrad|cancelad|reembols/i;
  const SHIPPED = /delivery|shipped|transit|enviad|entrega|camino|delivered/i;

  /**
   * The pages still worth reading, oldest need first: detail for orders without amounts, tracking
   * for orders that ship and haven't been checked for `trackEveryMs`. At most `max`.
   */
  function pendingFetches(orders, now, { trackEveryMs = 6 * 3600e3, max = 12 } = {}) {
    const out = [];
    for (const o of Object.values(orders)) {
      if (!o.detailAt) out.push({ id: o.id, page: "detail" });
      const ships = SHIPPED.test(o.status || "") || (DONE.test(o.status || "") && !o.trackedAt && !/cancel|refund|cancelad|reembols/i.test(o.status || ""));
      if (ships && (!o.trackedAt || (!DONE.test(o.status || "") && now - o.trackedAt > trackEveryMs))) {
        out.push({ id: o.id, page: "tracking" });
      }
    }
    return out.slice(0, max);
  }

  // ── Packages ──────────────────────────────────────────────────────────────

  /**
   * Orders grouped by tracking number. An order split over several boxes is listed in each, but
   * its lines (and amounts) count only in the first one, so nothing is invoiced twice.
   */
  function packagesOf(orders) {
    const byKey = new Map();
    const sorted = Object.values(orders).sort((a, b) => String(a.date || "").localeCompare(String(b.date || "")) || String(a.id).localeCompare(String(b.id)));
    for (const o of sorted) {
      (o.packages || []).forEach((p, i) => {
        if (!p.tracking) return;
        const key = p.tracking.toUpperCase();
        if (!byKey.has(key)) {
          byKey.set(key, { tracking: p.tracking, carrier: p.carrier || "", status: p.status || "", lastEvent: p.lastEvent || "",
            lastTime: p.lastTime || "", orders: [], charged: [], partOf: [] });
        }
        const pkg = byKey.get(key);
        if (!pkg.status && p.status) pkg.status = p.status;
        if (!pkg.orders.includes(o.id)) pkg.orders.push(o.id);
        if (i === 0) pkg.charged.push(o.id);
        else pkg.partOf.push(o.id);
      });
    }
    return [...byKey.values()];
  }

  /** The invoice of one package: its lines, shipping and total, from the orders charged to it. */
  function invoiceOf(pkg, orders) {
    const lines = [];
    let shipping = 0, discount = 0, currency = "USD";
    for (const id of pkg.charged) {
      const o = orders[id];
      if (!o) continue;
      currency = o.currency || currency;
      for (const l of o.lines || []) {
        lines.push({ order: id, store: o.store || "", title: l.title, sku: l.sku || "", qty: l.qty || 1, price: l.price || 0,
          amount: Math.round((l.price || 0) * (l.qty || 1) * 100) / 100 });
      }
      const subtotal = o.subtotal ?? (o.lines || []).reduce((s, l) => s + (l.price || 0) * (l.qty || 1), 0);
      // Whatever the order total has on top of its products: shipping, taxes and fees.
      if (o.total != null) {
        const extra = Math.round((o.total - subtotal + (o.discount || 0)) * 100) / 100;
        shipping += Math.max(0, extra);
      } else if (o.shipping) {
        shipping += o.shipping;
      }
      discount += o.discount || 0;
    }
    const subtotal = Math.round(lines.reduce((s, l) => s + l.amount, 0) * 100) / 100;
    shipping = Math.round(shipping * 100) / 100;
    discount = Math.round(discount * 100) / 100;
    return { tracking: pkg.tracking, carrier: pkg.carrier, orders: pkg.orders, partOf: pkg.partOf, currency, lines,
      subtotal, shipping, discount, total: Math.round((subtotal + shipping - discount) * 100) / 100 };
  }

  /** "INV-2026-0007": the next number for this year, kept per tracking so a reprint keeps it. */
  function invoiceNumber(numbers, tracking, year) {
    if (numbers[tracking]) return { number: numbers[tracking], numbers };
    const used = Object.values(numbers).filter((n) => n.startsWith(`INV-${year}-`)).map((n) => Number(n.slice(9)) || 0);
    const number = `INV-${year}-${String((used.length ? Math.max(...used) : 0) + 1).padStart(4, "0")}`;
    return { number, numbers: { ...numbers, [tracking]: number } };
  }

  /** One CSV row per product line, every package (for Excel / Google Sheets). */
  function csv(packages, orders) {
    const head = ["tracking", "carrier", "package_status", "order", "order_date", "store", "product", "variant", "qty", "unit_price", "amount", "currency"];
    const cell = (v) => {
      let s = String(v ?? "");
      if (/^[=+\-@]/.test(s)) s = "'" + s; // a spreadsheet must never run a product title
      return /[",\n;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    const rows = [head.join(",")];
    for (const p of packages) {
      const inv = invoiceOf(p, orders);
      for (const l of inv.lines) {
        rows.push([p.tracking, p.carrier, p.status, l.order, orders[l.order]?.date || "", l.store, l.title, l.sku, l.qty, l.price.toFixed(2), l.amount.toFixed(2), inv.currency].map(cell).join(","));
      }
    }
    return rows.join("\r\n") + "\r\n";
  }

  /** What Coucou shows (no product titles needed there, only counts and totals). */
  function summary(packages, orders) {
    return packages.map((p) => {
      const inv = invoiceOf(p, orders);
      return { tracking: p.tracking, carrier: p.carrier, status: p.status, lastEvent: p.lastEvent, lastTime: p.lastTime,
        orders: p.orders, items: inv.lines.reduce((s, l) => s + l.qty, 0), total: inv.total, currency: inv.currency };
    });
  }

  // ── A small PDF writer (Helvetica, one or more A4 pages) ──────────────────

  /** Text the standard PDF fonts can show: Latin-1, everything else becomes "?". */
  function pdfText(s) {
    return String(s).replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/[–—]/g, "-")
      .replace(/[^\x20-\x7E\xA0-\xFF]/g, "?").replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
  }

  /** Approximate Helvetica width (points per 1000 em) to wrap and right-align. */
  function textWidth(s, size) {
    let w = 0;
    for (const ch of String(s)) w += /[il.,:;'|!\s]/.test(ch) ? 278 : /[mwMW]/.test(ch) ? 833 : /[A-Z0-9]/.test(ch) ? 667 : 556;
    return (w * size) / 1000;
  }

  function wrap(s, size, width) {
    const words = String(s).split(/\s+/);
    const lines = [];
    let cur = "";
    for (const w of words) {
      const next = cur ? `${cur} ${w}` : w;
      if (textWidth(next, size) > width && cur) {
        lines.push(cur);
        cur = w;
      } else cur = next;
    }
    if (cur) lines.push(cur);
    return lines.length ? lines : [""];
  }

  /**
   * The invoice as PDF bytes (a Uint8Array). `buyer` is the user's own details from Coucou's
   * settings: { name, id, address, email, phone }. `labels` lets the caller translate.
   */
  const SPANISH = {
    title: "FACTURA", number: "N.º", date: "Fecha", buyer: "Comprador", idLabel: "Cédula/RUC", tracking: "Tracking", carrier: "Transportista",
    orders: "Pedidos de AliExpress", product: "Producto", order: "Pedido", qty: "Cant.", price: "P. unitario", amount: "Importe",
    subtotal: "Subtotal", shipping: "Envío, impuestos y cargos", discount: "Descuentos", total: "Total",
    note: "Emitida por el comprador a partir de sus propios pedidos de AliExpress, agrupados por el paquete en que llegaron. No es una factura emitida por AliExpress ni por los vendedores; los comprobantes originales de cada pedido están en aliexpress.com.",
    partOf: "También van en esta caja (cobrados en el paquete donde aparecen primero):",
  };

  function invoicePdf(inv, { buyer = {}, number = "", date = "", labels = {}, lang = "en" } = {}) {
    if (lang === "es") labels = { ...SPANISH, ...labels };
    const L = {
      title: "INVOICE", number: "No.", date: "Date", buyer: "Buyer", idLabel: "ID", tracking: "Tracking", carrier: "Carrier",
      orders: "AliExpress orders", product: "Product", order: "Order", qty: "Qty", price: "Unit price", amount: "Amount",
      subtotal: "Subtotal", shipping: "Shipping, taxes and fees", discount: "Discounts", total: "Total",
      note: "Issued by the buyer from their own AliExpress orders, grouped by the package they shipped in. It is not an invoice issued by AliExpress or the sellers; the original order receipts are available on aliexpress.com.",
      partOf: "Also in this box (charged on the package where they first appear):",
      ...labels,
    };
    const W = 595, H = 842, M = 42;
    const pages = [];
    let ops = [];
    let y = H - M;
    const newPage = () => { if (ops.length) pages.push(ops.join("\n")); ops = []; y = H - M; };
    const text = (x, yy, s, size = 9, bold = false) => ops.push(`BT /${bold ? "F2" : "F1"} ${size} Tf ${x.toFixed(1)} ${yy.toFixed(1)} Td (${pdfText(s)}) Tj ET`);
    const right = (x, yy, s, size = 9, bold = false) => text(x - textWidth(s, size), yy, s, size, bold);
    const rule = (yy) => ops.push(`0.8 G 0.5 w ${M} ${yy.toFixed(1)} m ${W - M} ${yy.toFixed(1)} l S 0 G`);
    const need = (h) => { if (y - h < M + 20) newPage(); };
    const money = (v) => `${inv.currency === "USD" ? "$" : inv.currency + " "}${v.toFixed(2)}`;

    text(M, y, L.title, 18, true);
    right(W - M, y, `${L.number} ${number}`, 10, true);
    y -= 16;
    right(W - M, y, `${L.date}: ${date}`, 9);
    y -= 22;
    text(M, y, L.buyer, 9, true);
    text(320, y, `${L.tracking}: ${inv.tracking}`, 9, true);
    y -= 13;
    const buyerLines = [buyer.name, buyer.id ? `${L.idLabel}: ${buyer.id}` : "", ...String(buyer.address || "").split(/\n/), buyer.email, buyer.phone].filter(Boolean);
    const right2 = [`${L.carrier}: ${inv.carrier || "-"}`, `${L.orders}:`, ...wrap(inv.orders.join(", "), 8.5, W - M - 320)];
    for (let i = 0; i < Math.max(buyerLines.length, right2.length); i++) {
      if (buyerLines[i]) text(M, y, buyerLines[i], 9);
      if (right2[i]) text(320, y, right2[i], i < 2 ? 9 : 8.5);
      y -= 12;
    }
    y -= 8;
    // Table
    const cols = { product: M, order: 318, qty: 420, price: 482, amount: W - M };
    const header = () => {
      rule(y + 10);
      text(cols.product, y, L.product, 8.5, true);
      text(cols.order, y, L.order, 8.5, true);
      right(cols.qty, y, L.qty, 8.5, true);
      right(cols.price, y, L.price, 8.5, true);
      right(cols.amount, y, L.amount, 8.5, true);
      y -= 6;
      rule(y);
      y -= 12;
    };
    header();
    for (const l of inv.lines) {
      const title = wrap(l.sku ? `${l.title} (${l.sku})` : l.title, 8.5, cols.order - cols.product - 10).slice(0, 3);
      need(title.length * 11 + 4);
      if (y === H - M) header();
      text(cols.product, y, title[0], 8.5);
      text(cols.order, y, l.order, 8);
      right(cols.qty, y, String(l.qty), 8.5);
      right(cols.price, y, money(l.price), 8.5);
      right(cols.amount, y, money(l.amount), 8.5);
      for (const extra of title.slice(1)) { y -= 11; text(cols.product, y, extra, 8.5); }
      if (l.store) { y -= 10; text(cols.product, y, l.store, 7); }
      y -= 14;
    }
    need(90);
    rule(y + 6);
    y -= 8;
    const totals = [[L.subtotal, inv.subtotal], [L.shipping, inv.shipping]];
    if (inv.discount) totals.push([L.discount, -inv.discount]);
    for (const [label, v] of totals) { right(cols.price, y, label, 9); right(cols.amount, y, money(v), 9); y -= 13; }
    right(cols.price, y, L.total, 11, true);
    right(cols.amount, y, money(inv.total), 11, true);
    y -= 26;
    if (inv.partOf.length) {
      need(30);
      for (const s of wrap(`${L.partOf} ${inv.partOf.join(", ")}`, 8, W - 2 * M)) { text(M, y, s, 8); y -= 11; }
      y -= 6;
    }
    need(40);
    for (const s of wrap(L.note, 7.5, W - 2 * M)) { text(M, y, s, 7.5); y -= 10; }
    newPage();

    // Assemble the file: catalog, pages, fonts, contents.
    const objs = [];
    const add = (s) => { objs.push(s); return objs.length; };
    const catalog = add("");
    const pagesObj = add("");
    const f1 = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
    const f2 = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>");
    const kids = [];
    for (const content of pages) {
      const bytes = latin1(content);
      const c = add(`<< /Length ${bytes.length} >>\nstream\n${content}\nendstream`);
      kids.push(add(`<< /Type /Page /Parent ${pagesObj} 0 R /MediaBox [0 0 ${W} ${H}] /Resources << /Font << /F1 ${f1} 0 R /F2 ${f2} 0 R >> >> /Contents ${c} 0 R >>`));
    }
    objs[catalog - 1] = `<< /Type /Catalog /Pages ${pagesObj} 0 R >>`;
    objs[pagesObj - 1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] /Count ${kids.length} >>`;
    let out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n";
    const offsets = [];
    objs.forEach((o, i) => { offsets.push(latin1(out).length); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
    const xref = latin1(out).length;
    out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("")}`;
    out += `trailer\n<< /Size ${objs.length + 1} /Root ${catalog} 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
    return latin1(out);
  }

  /** A string whose characters are all < 256, as bytes. */
  function latin1(s) {
    const b = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff;
    return b;
  }

  const api = { priceQty, amount, orderIdFrom, isoDate, priceBlock, mergeOrder, pendingFetches, packagesOf, invoiceOf, invoiceNumber, csv, summary, invoicePdf, pdfText, wrap };
  if (typeof module !== "undefined") module.exports = api;
  root.CoucouAli = api;
})(typeof self !== "undefined" ? self : globalThis);
