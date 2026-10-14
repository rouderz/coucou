// Renders Lumo's icons from dev/icon.html (the real character, drawn in code) at every size the
// apps and the website need. Needs Playwright's Chromium once: `npx playwright install chromium`.
//
//   npm run icons
//
// Writes: NotchBuddy/Assets.xcassets/AppIcon.appiconset (macOS app icon), MenuBarIcon.imageset
// (menu bar template), windows/src-tauri/icons (Windows / Linux, with icon.ico) and docs/media/icon.png.

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";

const WIN = join(dirname(fileURLToPath(import.meta.url)), "..");
const ROOT = join(WIN, "..");
const MAC = join(ROOT, "NotchBuddy", "Assets.xcassets");

let chromium;
try {
  ({ chromium } = await import("playwright"));
} catch {
  console.error("Playwright isn't installed: npm i -D playwright && npx playwright install chromium");
  process.exit(1);
}

const server = await createServer({ root: WIN, server: { port: 5188, strictPort: false }, logLevel: "error" });
await server.listen();
const base = server.resolvedUrls.local[0];
const browser = await chromium.launch();

async function render(kind, size) {
  const h = kind === "menubar" ? Math.round(size * 0.75) : size;
  const page = await browser.newPage({ viewport: { width: size, height: h } });
  await page.goto(`${base}dev/icon.html?kind=${kind}&size=${size}`);
  await page.waitForSelector("body[data-done]");
  const png = await page.locator("#c").screenshot({ omitBackground: true });
  await page.close();
  return png;
}

function write(path, data) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
  console.log("✓", path.slice(ROOT.length + 1));
}

function encodeICO(entries) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(entries.length, 4);
  const dir = Buffer.alloc(16 * entries.length);
  let offset = header.length + dir.length;
  entries.forEach((e, i) => {
    const o = i * 16;
    dir[o] = e.size >= 256 ? 0 : e.size;
    dir[o + 1] = e.size >= 256 ? 0 : e.size;
    dir.writeUInt16LE(1, o + 4);
    dir.writeUInt16LE(32, o + 6);
    dir.writeUInt32LE(e.png.length, o + 8);
    dir.writeUInt32LE(offset, o + 12);
    offset += e.png.length;
  });
  return Buffer.concat([header, dir, ...entries.map((e) => e.png)]);
}

// macOS app icon.
for (const pt of [16, 32, 128, 256, 512]) {
  write(join(MAC, "AppIcon.appiconset", `icon_${pt}x${pt}.png`), await render("mac", pt));
  write(join(MAC, "AppIcon.appiconset", `icon_${pt}x${pt}@2x.png`), await render("mac", pt * 2));
}
// macOS menu bar (template image, 24 × 18 pt).
for (const [scale, suffix] of [[1, ""], [2, "@2x"], [3, "@3x"]]) {
  write(join(MAC, "MenuBarIcon.imageset", `menubar${suffix}.png`), await render("menubar", 24 * scale));
}
// Windows / Linux.
const ICONS = join(WIN, "src-tauri", "icons");
write(join(ICONS, "32x32.png"), await render("full", 32));
write(join(ICONS, "128x128.png"), await render("full", 128));
write(join(ICONS, "128x128@2x.png"), await render("full", 256));
write(join(ICONS, "icon.png"), await render("full", 512));
const ico = [];
for (const size of [16, 24, 32, 48, 64, 128, 256]) ico.push({ size, png: await render("full", size) });
write(join(ICONS, "icon.ico"), encodeICO(ico));
// Website.
write(join(ROOT, "docs", "media", "icon.png"), await render("full", 256));

await browser.close();
await server.close();
