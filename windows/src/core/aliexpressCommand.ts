// "aliexpress facturas" typed in the chat: answered here, never sent to the model.
// English or Spanish; always starts with "aliexpress" so ordinary questions about orders still
// go to the chat. Same pattern as NotchBuddy/Sources/App/AliExpress.swift (AliExpressCommand).
//   aliexpress                       → refresh and say how many packages there are
//   aliexpress facturas | invoices   → one invoice per package, plus the CSV
//   aliexpress factura LP00123…      → the invoice of that package
//   aliexpress csv | excel           → the CSV only

export type AliOp = "sync" | "invoices" | "invoice" | "csv";
export interface AliCommand {
  op: AliOp;
  tracking?: string;
}

const COMMAND =
  /^\/?aliexpress(?:\s+(pedidos|orders|actualizar|refresh|sync|facturas|invoices|todas|all|factura|invoice|csv|excel))?(?:\s+([a-z0-9]{6,60}))?\s*[.!]?$/i;

export function parseAliCommand(text: string): AliCommand | null {
  const m = text.trim().match(COMMAND);
  if (!m) return null;
  const word = m[1]?.toLowerCase();
  const tracking = m[2]?.toUpperCase();
  switch (word) {
    case "facturas": case "invoices": case "todas": case "all":
      return { op: "invoices" };
    case "factura": case "invoice":
      return tracking ? { op: "invoice", tracking } : { op: "invoices" };
    case "csv": case "excel":
      return { op: "csv" };
    default:
      return tracking ? null : { op: "sync" };
  }
}
