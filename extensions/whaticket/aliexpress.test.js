// node --test extensions/whaticket/aliexpress.test.js
const { test } = require("node:test");
const assert = require("node:assert/strict");
const A = require("./aliexpress-core.js");

test("reads prices, dates and order ids the way AliExpress writes them", () => {
  assert.deepEqual(A.priceQty("$17.22   x1"), { currency: "USD", price: 17.22, qty: 1 });
  assert.deepEqual(A.priceQty("US $2.39x3"), { currency: "USD", price: 2.39, qty: 3 });
  assert.equal(A.priceQty("Free returns"), null);
  assert.equal(A.amount("$1,234.56"), 1234.56);
  assert.equal(A.amount("1.234,56 €"), 1234.56);
  assert.equal(A.amount("Total:$18.24"), 18.24);
  assert.equal(A.orderIdFrom("https://www.aliexpress.com/p/order/detail.html?orderId=8214937669763641"), "8214937669763641");
  assert.equal(A.orderIdFrom("https://x/p/tracking/index.html?tradeOrderId=821493766"), "821493766");
  assert.equal(A.isoDate("Date: Sep 21, 2026 | Ref. Number: 1"), "2026-09-21");
  assert.deepEqual(A.priceBlock([["Subtotal", "$5.61"], ["Shipping", "$7.07"], ["Total", "$12.68"]]),
    { subtotal: 5.61, shipping: 7.07, discount: null, total: 12.68 });
});

const orders = () => ({
  a: { id: "a", date: "2026-09-21", store: "Pins Store", status: "Awaiting delivery", currency: "USD", subtotal: 5.61, total: 12.68,
    lines: [{ title: "Pokémon pins", sku: "13", price: 2.39, qty: 1 }, { title: "Sakura pins", sku: "1", price: 3.22, qty: 1 }],
    packages: [{ carrier: "GOFO INC.", tracking: "GFUS01074935269124", status: "Delivered" }], detailAt: 1, trackedAt: 1 },
  b: { id: "b", date: "2026-09-21", store: "Mouse Store", status: "Awaiting delivery", currency: "USD", subtotal: 17.82, total: 18.9,
    lines: [{ title: "Gengar mouse pad", sku: "90x40", price: 17.82, qty: 1 }],
    packages: [{ carrier: "GOFO INC.", tracking: "gfus01074935269124" }], detailAt: 1, trackedAt: 1 },
  c: { id: "c", date: "2026-09-22", store: "Figure Store", status: "Awaiting delivery", currency: "USD", subtotal: 20, total: 20,
    lines: [{ title: "Figure", price: 10, qty: 2 }],
    packages: [{ carrier: "Cainiao", tracking: "LP001" }, { carrier: "Cainiao", tracking: "LP002" }], detailAt: 1, trackedAt: 1 },
});

test("orders that share a tracking number are one package", () => {
  const p = A.packagesOf(orders());
  assert.equal(p.length, 3);
  assert.deepEqual(p[0].orders, ["a", "b"]);
  assert.equal(p[0].status, "Delivered");
});

test("one invoice per package: lines, shipping and total, never charged twice", () => {
  const o = orders();
  const [box, lp1, lp2] = A.packagesOf(o);
  const inv = A.invoiceOf(box, o);
  assert.equal(inv.lines.length, 3);
  assert.equal(inv.subtotal, 23.43);
  assert.equal(inv.shipping, 8.15); // (12.68-5.61) + (18.90-17.82)
  assert.equal(inv.total, 31.58);
  // An order split over two boxes is charged on the first only, and named on the other.
  assert.equal(A.invoiceOf(lp1, o).total, 20);
  assert.equal(A.invoiceOf(lp2, o).total, 0);
  assert.deepEqual(A.invoiceOf(lp2, o).partOf, ["c"]);
});

test("invoice numbers are sequential per year and stable per package", () => {
  let n = {};
  let r = A.invoiceNumber(n, "T1", 2026); n = r.numbers; assert.equal(r.number, "INV-2026-0001");
  r = A.invoiceNumber(n, "T2", 2026); n = r.numbers; assert.equal(r.number, "INV-2026-0002");
  assert.equal(A.invoiceNumber(n, "T1", 2026).number, "INV-2026-0001");
});

test("the PDF is a valid file with the buyer, the tracking and the totals", () => {
  const o = orders();
  const inv = A.invoiceOf(A.packagesOf(o)[0], o);
  const bytes = A.invoicePdf(inv, { buyer: { name: "Ana Pérez", id: "0912345678", address: "Av. 1\nGuayaquil" }, number: "INV-2026-0001", date: "2026-10-06" });
  const text = Buffer.from(bytes).toString("latin1");
  assert.ok(text.startsWith("%PDF-1.4"));
  assert.ok(text.trimEnd().endsWith("%%EOF"));
  assert.ok(text.includes("(Ana P\xe9rez)"));
  assert.ok(text.includes("GFUS01074935269124"));
  assert.ok(text.includes("$31.58"));
  // xref offsets point at the objects
  const xref = Number(/startxref\n(\d+)/.exec(text)[1]);
  assert.equal(text.slice(xref, xref + 4), "xref");
  const first = Number(/\n0000000000 65535 f \n(\d{10})/.exec(text)[1]);
  assert.equal(text.slice(first, first + 7), "1 0 obj");
});

test("CSV for Excel / Sheets: one row per product, formulas neutralised", () => {
  const o = orders();
  o.a.lines[0].title = "=HYPERLINK(1)";
  const out = A.csv(A.packagesOf(o), o).split("\r\n");
  assert.equal(out[0].split(",")[0], "tracking");
  assert.equal(out.length, 1 + 3 + 1 + 1); // header, box lines, LP001 line, trailing ""
  assert.ok(out[1].includes("'=HYPERLINK(1)"));
});

test("what still needs reading: detail for missing amounts, tracking for parcels on the way", () => {
  const now = 10 * 3600e3;
  const o = {
    x: { id: "x", status: "Awaiting shipment" },
    y: { id: "y", status: "Awaiting delivery", detailAt: 1, trackedAt: now - 7 * 3600e3 },
    z: { id: "z", status: "Completed", detailAt: 1, trackedAt: 1 },
    w: { id: "w", status: "Completed", detailAt: 1 },
  };
  assert.deepEqual(A.pendingFetches(o, now), [{ id: "x", page: "detail" }, { id: "y", page: "tracking" }, { id: "w", page: "tracking" }]);
  const merged = A.mergeOrder({ id: "y", lines: [{ title: "detail" }], linesFromDetail: true }, { id: "y", lines: [{ title: "list" }], source: "list" }, 5);
  assert.equal(merged.lines[0].title, "detail");
});
