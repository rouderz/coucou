// Coucou for AliExpress — the pure part, shared by the content script (aliexpress.js), the
// background worker (background.js) and the tests (aliexpress.test.js).
//
// AliExpress splits one checkout into one order per store, then often ships several orders in a
// single box with one tracking number. Here the orders read from the user's own pages are grouped
// by that tracking number into packages, and one invoice (PDF) and one CSV row set are made per
// package.
//
// The invoice is the buyer's own document built from their orders: it lists the AliExpress order
// numbers it comes from and never imitates an AliExpress-issued invoice (no AliExpress name, logo
// or layout).

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

  const MONTHS = {
    jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
    ene: 1, abr: 4, ago: 8, dic: 12, set: 9,
  };

  /**
   * When an order was placed, as "2026-10-01 10:23" (or "2026-10-01" without a time); null when
   * unreadable. "Oct 1, 2026 10:23:45", "1 oct 2026, 10:23", "2026-10-01 10:23:45".
   */
  function dateTime(text) {
    const s = String(text);
    const pad = (n) => String(Number(n)).padStart(2, "0");
    const time = (rest) => {
      const t = /(\d{1,2}):(\d{2})(?::\d{2})?\s*([AaPp]\.?[Mm]\.?)?/.exec(rest || "");
      if (!t) return "";
      let h = Number(t[1]);
      if (t[3] && /p/i.test(t[3]) && h < 12) h += 12;
      if (t[3] && /a/i.test(t[3]) && h === 12) h = 0;
      return ` ${pad(h)}:${t[2]}`;
    };
    let m = /(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/.exec(s);
    if (m) return `${m[1]}-${pad(m[2])}-${pad(m[3])}${time(s.slice(m.index + m[0].length))}`;
    m = /([A-Za-zé]{3,10})\.? (\d{1,2}),? (\d{4})/.exec(s);
    if (m && MONTHS[m[1].slice(0, 3).toLowerCase()]) {
      return `${m[3]}-${pad(MONTHS[m[1].slice(0, 3).toLowerCase()])}-${pad(m[2])}${time(s.slice(m.index + m[0].length))}`;
    }
    m = /(\d{1,2}) (?:de )?([A-Za-zé]{3,10})\.?,? (?:de )?(\d{4})/.exec(s);
    if (m && MONTHS[m[2].slice(0, 3).toLowerCase()]) {
      return `${m[3]}-${pad(MONTHS[m[2].slice(0, 3).toLowerCase()])}-${pad(m[1])}${time(s.slice(m.index + m[0].length))}`;
    }
    return null;
  }

  /**
   * What the product is, without the search keywords sellers pile on: the title up to its first
   * comma or dash, at most about 60 characters.
   */
  function shortTitle(title) {
    const t = String(title || "").replace(/\s+/g, " ").trim();
    const parts = t.split(/\s*[,，|;]\s*|\s+[-–—]\s+/).filter(Boolean);
    let out = parts[0] || t;
    // "Camiseta, Hawaiana, ..." — a first piece this short says too little; keep the next one.
    if (out.length < 14 && parts[1]) out = `${out}, ${parts[1]}`;
    if (out.length > 60) {
      const cut = out.slice(0, 60);
      out = cut.slice(0, Math.max(cut.lastIndexOf(" "), 40)).replace(/[\s,.;:-]+$/, "") + "...";
    }
    return out;
  }

  /**
   * A product picture's address, or null: only AliExpress's own image servers, https, and the JPEG
   * version rather than AVIF / WebP ("...jpg_220x220.jpg_.avif" → "...jpg_220x220.jpg").
   */
  function imageUrl(raw) {
    let s = String(raw || "").trim();
    const bg = /url\(["']?([^"')]+)["']?\)/.exec(s);
    if (bg) s = bg[1];
    if (s.startsWith("//")) s = "https:" + s;
    let u;
    try { u = new URL(s); } catch { return null; }
    if (u.protocol !== "https:" || !/(^|\.)(alicdn\.com|aliexpress-media\.com)$/.test(u.hostname)) return null;
    u.pathname = u.pathname.replace(/_\.(avif|webp)$/i, "");
    u.search = "";
    return u.toString();
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
    for (const k of ["date", "time", "status", "store", "currency", "subtotal", "shipping", "discount", "total"]) {
      if (update[k] !== undefined && update[k] !== null && update[k] !== "") o[k] = update[k];
    }
    if (update.lines && update.lines.length && (update.source === "detail" || !o.linesFromDetail)) {
      // A page that showed no picture for a line keeps the one another page showed.
      const before = o.lines || [];
      o.lines = update.lines.map((l, i) => {
        if (l.image) return l;
        const same = before.find((b) => b.title === l.title && b.image) || (before[i] && before[i].image && before.length === update.lines.length ? before[i] : null);
        return same ? { ...l, image: same.image } : l;
      });
      if (update.source === "detail") o.linesFromDetail = true;
    } else if (update.lines && o.lines) {
      // The list (a summary) can still bring pictures the detail page didn't have.
      o.lines = o.lines.map((l) => (l.image ? l : { ...l, image: (update.lines.find((u) => u.title === l.title && u.image) || {}).image }));
    }
    if (update.source === "detail") {
      o.detailAt = now;
      o.detailV = DETAIL_VERSION;
    }
    if (update.packages) {
      o.packages = update.packages;
      o.trackedAt = now;
    }
    o.updatedAt = now;
    return o;
  }

  /** What the detail reader takes from the page; bump it to read every order's detail again. */
  const DETAIL_VERSION = 2;
  const DONE = /complet|finish|closed|cancel|refund|finalizad|cerrad|cancelad|reembols/i;
  const SHIPPED = /delivery|shipped|transit|enviad|entrega|camino|delivered/i;

  /**
   * The pages still worth reading, oldest need first: detail for orders without amounts, tracking
   * for orders that ship and haven't been checked for `trackEveryMs`. At most `max`.
   */
  function pendingFetches(orders, now, { trackEveryMs = 6 * 3600e3, max = 12 } = {}) {
    const out = [];
    for (const o of Object.values(orders)) {
      // Read again when this version reads more from the page (pictures, order time) than the last one.
      if (!o.detailAt || (o.detailV || 1) < DETAIL_VERSION) out.push({ id: o.id, page: "detail" });
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
        lines.push({ order: id, store: o.store || "", time: o.time || o.date || "", title: l.title, sku: l.sku || "", image: l.image || null,
          qty: l.qty || 1, price: l.price || 0, amount: Math.round((l.price || 0) * (l.qty || 1) * 100) / 100 });
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
    const head = ["tracking", "carrier", "package_status", "order", "order_time", "store", "product", "variant", "qty", "unit_price", "amount", "currency"];
    const cell = (v) => {
      let s = String(v ?? "");
      if (/^[=+\-@]/.test(s)) s = "'" + s; // a spreadsheet must never run a product title
      return /[",\n;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
    };
    const rows = [head.join(",")];
    for (const p of packages) {
      const inv = invoiceOf(p, orders);
      for (const l of inv.lines) {
        rows.push([p.tracking, p.carrier, p.status, l.order, l.time, l.store, l.title, l.sku, l.qty, l.price.toFixed(2), l.amount.toFixed(2), inv.currency].map(cell).join(","));
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

  // ── A small PDF writer (Helvetica, pictures, one or more A4 pages) ───────

  /** Text the standard PDF fonts can show: Latin-1, everything else becomes "?". */
  function pdfText(s) {
    return String(s).replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/[–—]/g, "-").replace(/…/g, "...")
      .replace(/[^\x20-\x7E\xA0-\xFF]/g, "?").replace(/\\/g, "\\\\").replace(/\(/g, "\\(").replace(/\)/g, "\\)");
  }

  /** Approximate Helvetica width (points per 1000 em) to wrap and right-align. */
  function textWidth(s, size, bold = false) {
    let w = 0;
    for (const ch of String(s)) w += /[il.,:;'|!\s]/.test(ch) ? 278 : /[mwMW]/.test(ch) ? 833 : /[A-Z0-9]/.test(ch) ? 667 : 556;
    return (w * size * (bold ? 1.06 : 1)) / 1000;
  }

  function wrap(s, size, width, bold = false) {
    const words = String(s).split(/\s+/);
    const lines = [];
    let cur = "";
    for (const w of words) {
      const next = cur ? `${cur} ${w}` : w;
      if (textWidth(next, size, bold) > width && cur) {
        lines.push(cur);
        cur = w;
      } else cur = next;
    }
    if (cur) lines.push(cur);
    return lines.length ? lines : [""];
  }

  const SPANISH = {
    title: "FACTURA", number: "Factura N.º", date: "Fecha", buyer: "Facturado a", idLabel: "Cédula/RUC", shipment: "Envío",
    tracking: "Tracking", carrier: "Transportista", items: "Artículos", orders: "Pedidos",
    product: "Producto", qty: "Cant.", price: "P. unitario", amount: "Importe", order: "Pedido", placed: "Realizado",
    subtotal: "Subtotal", shipping: "Envío, impuestos y cargos", discount: "Descuentos", total: "Total",
    partOf: "También van en esta caja (cobrados en el paquete donde aparecen primero):", page: "Página",
    months: ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"], dayFirst: true,
  };

  /** "2026-10-01 10:23" → "Oct 1, 2026 · 10:23" / "1 oct 2026 · 10:23". */
  function niceDate(iso, L) {
    const m = /^(\d{4})-(\d{2})-(\d{2})(?: (\d{2}:\d{2}))?/.exec(String(iso || ""));
    if (!m) return String(iso || "");
    const mon = L.months[Number(m[2]) - 1];
    const day = Number(m[3]);
    const d = L.dayFirst ? `${day} ${mon} ${m[1]}` : `${mon} ${day}, ${m[1]}`;
    return m[4] ? `${d} · ${m[4]}` : d;
  }

  /**
   * The invoice as PDF bytes (a Uint8Array). `buyer` is the user's own details from Coucou's
   * settings: { name, id, address, email, phone }. `images` maps a line's picture address to a small
   * JPEG { w, h, data } (data: a binary string), made by the background worker; lines without one
   * get a plain placeholder. `labels` lets the caller translate.
   */
  function invoicePdf(inv, { buyer = {}, number = "", date = "", labels = {}, lang = "en", images = {} } = {}) {
    if (lang === "es") labels = { ...SPANISH, ...labels };
    const L = {
      title: "INVOICE", number: "Invoice No.", date: "Date", buyer: "Billed to", idLabel: "ID", shipment: "Shipment",
      tracking: "Tracking", carrier: "Carrier", items: "Items", orders: "Orders",
      product: "Product", qty: "Qty", price: "Unit price", amount: "Amount", order: "Order", placed: "Placed",
      subtotal: "Subtotal", shipping: "Shipping, taxes and fees", discount: "Discounts", total: "Total",
      partOf: "Also in this box (charged on the package where they first appear):", page: "Page",
      months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
      ...labels,
    };
    const W = 595, H = 842, M = 40;
    const INK = "0.12 0.14 0.19", MUTED = "0.45 0.47 0.52", LINE = "0.88 0.89 0.91", BAND = "0.96 0.965 0.975";
    const ACCENT = "0.17 0.35 0.76", ACCENT_SOFT = "0.93 0.95 0.99";
    const pages = [];
    let ops = [];
    let y = 0;
    const money = (v) => `${v < 0 ? "-" : ""}${inv.currency === "USD" ? "$" : inv.currency + " "}${Math.abs(v).toFixed(2)}`;

    const fill = (rgb) => ops.push(`${rgb} rg`);
    const rect = (x, yy, w, h, rgb) => { fill(rgb); ops.push(`${x.toFixed(1)} ${yy.toFixed(1)} ${w.toFixed(1)} ${h.toFixed(1)} re f`); };
    const hline = (x1, x2, yy, rgb = LINE, w = 0.6) => ops.push(`${rgb} RG ${w} w ${x1.toFixed(1)} ${yy.toFixed(1)} m ${x2.toFixed(1)} ${yy.toFixed(1)} l S`);
    const text = (x, yy, s, size = 9, bold = false, rgb = INK) => { fill(rgb); ops.push(`BT /${bold ? "F2" : "F1"} ${size} Tf ${x.toFixed(1)} ${yy.toFixed(1)} Td (${pdfText(s)}) Tj ET`); };
    const right = (x, yy, s, size = 9, bold = false, rgb = INK) => text(x - textWidth(s, size, bold), yy, s, size, bold, rgb);

    // Pictures: one XObject per distinct address.
    const xobjects = [];
    const imageName = new Map();
    for (const l of inv.lines) {
      const img = l.image && images[l.image];
      if (img && img.data && !imageName.has(l.image)) {
        imageName.set(l.image, `Im${xobjects.length + 1}`);
        xobjects.push(img);
      }
    }
    const picture = (url, x, yy, box) => {
      const name = url && imageName.get(url);
      if (!name) {
        rect(x, yy, box, box, BAND);
        return;
      }
      const img = images[url];
      const s = Math.min(box / img.w, box / img.h);
      const w = img.w * s, h = img.h * s;
      ops.push(`q ${w.toFixed(1)} 0 0 ${h.toFixed(1)} ${(x + (box - w) / 2).toFixed(1)} ${(yy + (box - h) / 2).toFixed(1)} cm /${name} Do Q`);
    };

    // ── Header (first page) ──
    const startPage = () => { ops = []; y = H - M; rect(0, H - 6, W, 6, ACCENT); };
    const endPage = () => { pages.push(ops); };
    startPage();
    text(M, y - 22, L.title, 24, true);
    right(W - M, y - 8, L.number, 8, false, MUTED);
    right(W - M, y - 22, number, 13, true);
    right(W - M, y - 36, `${L.date}: ${niceDate(date, L)}`, 8.5, false, MUTED);
    y -= 62;

    // Two cards: who is billed, and the shipment.
    const cardTop = y;
    const colW = (W - 2 * M - 16) / 2;
    const buyerLines = [buyer.id ? `${L.idLabel}: ${buyer.id}` : "", ...String(buyer.address || "").split(/\n/), buyer.email, buyer.phone]
      .filter(Boolean).flatMap((s) => wrap(s, 8.5, colW - 24));
    const items = inv.lines.reduce((s2, l) => s2 + l.qty, 0);
    const shipRows = [[L.tracking, inv.tracking], [L.carrier, inv.carrier || "-"], [L.items, String(items)], [L.orders, String(inv.orders.length)]];
    const cardH = Math.max(34 + 12 * buyerLines.length, 22 + 13 * shipRows.length) + 12;
    rect(M, cardTop - cardH, colW, cardH, BAND);
    rect(M + colW + 16, cardTop - cardH, colW, cardH, BAND);
    text(M + 12, cardTop - 16, L.buyer.toUpperCase(), 7, true, MUTED);
    text(M + 12, cardTop - 31, buyer.name || "-", 11, true);
    buyerLines.forEach((s2, i) => text(M + 12, cardTop - 45 - 12 * i, s2, 8.5, false, MUTED));
    const sx = M + colW + 28;
    text(sx, cardTop - 16, L.shipment.toUpperCase(), 7, true, MUTED);
    shipRows.forEach(([k, v], i) => {
      text(sx, cardTop - 31 - 13 * i, k, 8.5, false, MUTED);
      text(sx + 70, cardTop - 31 - 13 * i, v, 8.5, i === 0);
    });
    y = cardTop - cardH - 22;

    // ── Table ──
    const IMG = 34;
    const cols = { img: M + 8, product: M + 8 + IMG + 10, qty: 392, price: 468, amount: W - M - 8 };
    const productW = cols.qty - 40 - cols.product;
    const tableHeader = () => {
      rect(M, y - 6, W - 2 * M, 20, INK);
      text(cols.product, y, L.product.toUpperCase(), 7.5, true, "1 1 1");
      right(cols.qty, y, L.qty.toUpperCase(), 7.5, true, "1 1 1");
      right(cols.price, y, L.price.toUpperCase(), 7.5, true, "1 1 1");
      right(cols.amount, y, L.amount.toUpperCase(), 7.5, true, "1 1 1");
      y -= 24;
    };
    const room = (h) => {
      if (y - h >= M + 30) return;
      endPage();
      startPage();
      y -= 10;
      tableHeader();
    };
    tableHeader();

    let lastOrder = null;
    for (const l of inv.lines) {
      const title = wrap(shortTitle(l.title), 9, productW, true).slice(0, 2);
      const variant = l.sku ? wrap(l.sku, 7.5, productW).slice(0, 1) : [];
      const rowH = Math.max(IMG + 10, 12 * title.length + 10 * variant.length + 12);
      if (l.order !== lastOrder) {
        // One band per order: its number, when it was placed and the store — not repeated per line.
        room(22 + rowH);
        rect(M, y - 6, W - 2 * M, 18, ACCENT_SOFT);
        rect(M, y - 6, 2.5, 18, ACCENT);
        let x = M + 10;
        text(x, y, `${L.order} ${l.order}`, 8, true);
        x += textWidth(`${L.order} ${l.order}`, 8, true) + 14;
        if (l.time) { text(x, y, `${L.placed}: ${niceDate(l.time, L)}`, 8, false, MUTED); x += textWidth(`${L.placed}: ${niceDate(l.time, L)}`, 8) + 14; }
        if (l.store) right(cols.amount, y, l.store.length > 40 ? l.store.slice(0, 38) + "..." : l.store, 8, false, MUTED);
        y -= 22;
        lastOrder = l.order;
      } else {
        room(rowH);
      }
      const top = y + 8;
      picture(l.image, cols.img, top - IMG, IMG);
      let ty = top - 10;
      title.forEach((s2) => { text(cols.product, ty, s2, 9, true); ty -= 12; });
      variant.forEach((s2) => { text(cols.product, ty, s2, 7.5, false, MUTED); ty -= 10; });
      const my = top - 13;
      right(cols.qty, my, String(l.qty), 9);
      right(cols.price, my, money(l.price), 9, false, MUTED);
      right(cols.amount, my, money(l.amount), 9, true);
      y -= rowH;
      hline(M, W - M, y + 6);
      y -= 6;
    }

    // ── Totals ──
    const totals = [[L.subtotal, inv.subtotal], [L.shipping, inv.shipping]];
    if (inv.discount) totals.push([L.discount, -inv.discount]);
    room(16 * totals.length + 50);
    y -= 6;
    const tx = 300;
    for (const [label, v] of totals) {
      text(tx, y, label, 9, false, MUTED);
      right(cols.amount, y, money(v), 9);
      y -= 16;
    }
    y -= 8;
    rect(tx - 10, y - 10, W - M - tx + 10, 26, INK);
    text(tx, y, L.total.toUpperCase(), 10, true, "1 1 1");
    right(cols.amount, y, money(inv.total), 12, true, "1 1 1");
    y -= 40;
    if (inv.partOf.length) {
      const lines = wrap(`${L.partOf} ${inv.partOf.join(", ")}`, 8, W - 2 * M);
      room(12 * lines.length);
      for (const s2 of lines) { text(M, y, s2, 8, false, MUTED); y -= 12; }
    }
    endPage();

    // Footer on every page, now that the count is known.
    pages.forEach((p, i) => {
      ops = p;
      hline(M, W - M, M - 2);
      text(M, M - 16, `${number}  ·  ${inv.tracking}`, 7.5, false, MUTED);
      right(W - M, M - 16, `${L.page} ${i + 1}/${pages.length}`, 7.5, false, MUTED);
    });

    // ── Assemble the file: catalog, pages, fonts, pictures, contents ──
    const objs = [];
    const add = (o) => { objs.push(o); return objs.length; };
    const catalog = add("");
    const pagesObj = add("");
    const f1 = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
    const f2 = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>");
    const imgRefs = xobjects.map((img, i) =>
      `/Im${i + 1} ${add(`<< /Type /XObject /Subtype /Image /Width ${img.w} /Height ${img.h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${img.data.length} >>\nstream\n${img.data}\nendstream`)} 0 R`);
    const resources = `<< /Font << /F1 ${f1} 0 R /F2 ${f2} 0 R >>${imgRefs.length ? ` /XObject << ${imgRefs.join(" ")} >>` : ""} >>`;
    const kids = [];
    for (const p of pages) {
      const content = p.join("\n");
      const c = add(`<< /Length ${latin1(content).length} >>\nstream\n${content}\nendstream`);
      kids.push(add(`<< /Type /Page /Parent ${pagesObj} 0 R /MediaBox [0 0 ${W} ${H}] /Resources ${resources} /Contents ${c} 0 R >>`));
    }
    objs[catalog - 1] = `<< /Type /Catalog /Pages ${pagesObj} 0 R >>`;
    objs[pagesObj - 1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] /Count ${kids.length} >>`;
    // Every character is one byte (text is Latin-1, pictures are binary strings), so offsets are lengths.
    let out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n";
    const offsets = [];
    objs.forEach((o, i) => { offsets.push(out.length); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
    const xref = out.length;
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

  const api = { priceQty, amount, orderIdFrom, isoDate, dateTime, shortTitle, imageUrl, priceBlock, mergeOrder, pendingFetches, packagesOf, invoiceOf, invoiceNumber, csv, summary, invoicePdf, pdfText, wrap };
  if (typeof module !== "undefined") module.exports = api;
  root.CoucouAli = api;
})(typeof self !== "undefined" ? self : globalThis);
