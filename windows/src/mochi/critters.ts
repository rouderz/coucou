// The character the user picked (Settings → Appearance → Character). Port of
// NotchBuddy/Sources/App/Bot/Critter.swift — keep the two in step.
//
// Every character shares the engine (eyes, blush, badges, particles, hands, the upload
// mailbox morph). A character only brings its silhouette (sampled by angle, so it still
// morphs into the mailbox), its colours and a few drawn extras that react to the state.
// Its name is the one the interface uses ("Ask Lumo", "Hey Pip"): see botName().

export type CritterId = "bao" | "pip" | "nube" | "lumo" | "tecla";

export const CRITTERS: readonly CritterId[] = ["bao", "pip", "nube", "lumo", "tecla"];
export const DEFAULT_CRITTER: CritterId = "bao";

let current: CritterId = DEFAULT_CRITTER;
/** The character picked in Settings (the island and the settings window keep it current). */
export function setCurrentCritter(c: CritterId) {
  current = c;
}
/** Its name, for the interface ("Ask Lumo", "Hey Pip"). */
export function botName(): string {
  return CRITTER_INFO[current].name;
}

export function isCritter(v: unknown): v is CritterId {
  return typeof v === "string" && (CRITTERS as readonly string[]).includes(v);
}

export const CRITTER_INFO: Record<CritterId, { name: string; tagline: string }> = {
  bao: { name: "Bao", tagline: "A steamed bun that steams while it works" },
  pip: { name: "Pip", tagline: "A bean with a sprout that tells how things go" },
  nube: { name: "Nube", tagline: "A little cloud: rain on errors, sun when done" },
  lumo: { name: "Lumo", tagline: "A glowing jellyfish that wiggles while it works" },
  tecla: { name: "Tecla", tagline: "A keycap that presses itself while it types" },
};

type RGB = readonly [number, number, number];

export interface CritterPalette {
  top: RGB;
  bottom: RGB;
  ink: string;
  blush: RGB;     // 0…255
  accent: string;
  accent2: string;
}

const hex = (h: string): RGB => {
  const v = parseInt(h.replace("#", ""), 16);
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
};

export const PALETTES: Record<CritterId, CritterPalette> = {
  bao: { top: hex("#F8EDDC"), bottom: hex("#E2CDAE"), ink: "#3B2A1E", blush: [242, 160, 126], accent: "#D2B994", accent2: "#FFFFFF" },
  pip: { top: hex("#C4E6A3"), bottom: hex("#93C46E"), ink: "#2E3B26", blush: [244, 154, 138], accent: "#5DB36B", accent2: "#4E9A5A" },
  nube: { top: hex("#F5F7FF"), bottom: hex("#C9D4F2"), ink: "#2B3350", blush: [245, 163, 181], accent: "#FFD36E", accent2: "#7FB2FF" },
  lumo: { top: hex("#D6CBFF"), bottom: hex("#AE9CF7"), ink: "#2E2357", blush: [249, 168, 212], accent: "#A996F5", accent2: "#FFFFFF" },
  tecla: { top: hex("#5FBFA2"), bottom: hex("#3E957B"), ink: "#1F3D35", blush: [245, 158, 139], accent: "#A3ECD5", accent2: "#86DCC0" },
};

/** How far the eyes and blush sit above Mochi's, in units of ry (Lumo's face is up in its dome). */
export function faceLift(c: CritterId): number {
  return c === "lumo" ? 0.3 : 0;
}

const spow = (v: number, e: number) => (v >= 0 ? Math.pow(v, e) : -Math.pow(-v, e));

/** Ray / rounded-rect intersection (half-sizes W × H, corner radius cr). */
export function rrPointShared(ca: number, sa: number, W: number, H: number, cr: number): { x: number; y: number } {
  const eps = 1e-6;
  const kx = ca >= 0 ? 1 : -1;
  const ky = sa >= 0 ? 1 : -1;
  const cx = kx * (W - cr);
  const cy = ky * (H - cr);
  const dot = ca * cx + sa * cy;
  const disc = dot * dot - (cx * cx + cy * cy - cr * cr);
  if (disc >= 0) {
    const t = dot + Math.sqrt(disc);
    if (t > eps) {
      const px = ca * t, py = sa * t;
      if (Math.abs(px) >= W - cr - eps && Math.abs(py) >= H - cr - eps) return { x: px, y: py };
    }
  }
  if (Math.abs(sa) > eps) {
    const t = (ky * H) / sa;
    if (t > eps && Math.abs(ca * t) <= W - cr + eps) return { x: ca * t, y: ky * H };
  }
  if (Math.abs(ca) > eps) {
    const t = (kx * W) / ca;
    if (t > eps && Math.abs(sa * t) <= H - cr + eps) return { x: kx * W, y: sa * t };
  }
  return { x: ca * W, y: sa * H };
}

/**
 * Point on the outline in direction `a` (radians, y down: sin > 0 is the bottom half)
 * for a body of half-size rx × ry.
 */
export function outline(c: CritterId, a: number, rx: number, ry: number, R: number): { x: number; y: number } {
  const ca = Math.cos(a), sa = Math.sin(a);
  switch (c) {
    case "bao": {
      const x = rx * 0.98 * spow(ca, 0.8);
      const y = sa < 0 ? ry * 1.02 * spow(sa, 0.9) : ry * 0.62 * spow(sa, 0.35);
      return { x, y: y + ry * 0.08 };
    }
    case "pip": {
      const x = rx * 0.96 * spow(ca, 0.85);
      let y = ry * 0.86 * spow(sa, 0.85);
      if (sa < 0) y += ry * 0.14 * Math.exp(-Math.pow(ca / 0.35, 2)) * -sa;
      return { x, y: y + ry * 0.12 };
    }
    case "nube": {
      const pill = rrPointShared(ca, sa, 0.98, 0.62, 0.45);
      let best = Math.hypot(pill.x, pill.y);
      for (const [px, py, r] of [[-0.52, -0.1, 0.5], [0.02, -0.35, 0.62], [0.56, -0.05, 0.46]]) {
        const dc = ca * px + sa * py;
        const disc = dc * dc - (px * px + py * py - r * r);
        if (disc >= 0) best = Math.max(best, dc + Math.sqrt(disc));
      }
      return { x: best * ca * rx, y: best * sa * ry + ry * 0.05 };
    }
    case "lumo": {
      const x = rx * 0.96 * spow(ca, 0.9);
      const y = sa < 0
        ? ry * 1.12 * spow(sa, 0.85)
        : ry * (0.3 * Math.pow(sa, 0.5) + 0.12 * Math.abs(Math.sin(2 * Math.PI * ca)) * sa);
      return { x, y: y + ry * 0.2 };
    }
    case "tecla":
      return rrPointShared(ca, sa, rx * 0.97, ry * 0.92, R * 0.36);
  }
}

const headTop = (c: CritterId, rx: number, ry: number, R: number) => outline(c, Math.PI * 1.5, rx, ry, R).y;
const bottomY = (c: CritterId, rx: number, ry: number, R: number) => outline(c, Math.PI * 0.5, rx, ry, R).y;

/** What the extras need to know from the engine. */
export interface CritterCtx {
  critter: CritterId;
  state: string;
  morph: number;
  isMini: boolean;
}

const busy = (s: string) => s === "working" || s === "thinking" || s === "searching";
const t = () => performance.now() / 1000;

function rgbaHex(h: string, a: number): string {
  const [r, g, b] = hex(h);
  return `rgba(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)},${a})`;
}

/** Tecla bobs down like a pressed key while busy. Call on the body transform. */
export function critterPress(x: CanvasRenderingContext2D, k: CritterCtx, R: number) {
  if (k.critter !== "tecla" || !busy(k.state) || k.isMini || k.morph >= 0.5) return;
  const p = Math.pow(Math.max(0, Math.sin(t() * 11)), 3);
  x.translate(0, p * R * 0.05);
  x.scale(1, 1 - p * 0.06);
}

/** Extras behind the body (sprout, tentacles, sun, steam, rain), in body coordinates. */
export function drawCritterBack(x: CanvasRenderingContext2D, k: CritterCtx, R: number, rx: number, ry: number) {
  const alpha = Math.max(0, 1 - k.morph * 2);
  if (k.isMini || alpha <= 0.01) return;
  const pal = PALETTES[k.critter];
  const now = t();
  x.save();
  x.globalAlpha *= alpha;
  x.lineCap = "round";
  x.lineJoin = "round";
  switch (k.critter) {
    case "bao": {
      if (!busy(k.state)) break;
      const top = headTop(k.critter, rx, ry, R);
      x.lineWidth = R * 0.06;
      for (let i = 0; i < 3; i++) {
        const x0 = (i - 1) * rx * 0.37;
        const p = (now * 0.6 + i * 0.33) % 1;
        const y0 = top - R * 0.08 - p * R * 0.35;
        x.beginPath();
        for (let j = 0; j <= 10; j++) {
          const px = x0 + Math.sin(j * 0.9 + now * 4 + i) * R * 0.06;
          const py = y0 - j * R * 0.04;
          if (j === 0) x.moveTo(px, py); else x.lineTo(px, py);
        }
        x.strokeStyle = rgbaHex(pal.accent2, Math.sin(p * Math.PI) * 0.55);
        x.stroke();
      }
      break;
    }
    case "pip":
      drawSprout(x, k, R, rx, ry, now);
      break;
    case "nube": {
      if (k.state === "finished") {
        const sx = -rx * 0.62, sy = -ry * 0.72, sr = R * 0.26;
        x.strokeStyle = pal.accent;
        x.fillStyle = pal.accent;
        x.lineWidth = R * 0.06;
        for (let i = 0; i < 8; i++) {
          const a = (i / 8) * Math.PI * 2 + now * 0.4;
          x.beginPath();
          x.moveTo(sx + Math.cos(a) * sr * 1.3, sy + Math.sin(a) * sr * 1.3);
          x.lineTo(sx + Math.cos(a) * sr * 1.65, sy + Math.sin(a) * sr * 1.65);
          x.stroke();
        }
        x.beginPath();
        x.arc(sx, sy, sr, 0, Math.PI * 2);
        x.fill();
      }
      if (k.state === "error" || k.state === "ratelimit") {
        const b = bottomY(k.critter, rx, ry, R);
        for (let i = 0; i < 3; i++) {
          const p = (now * 1.2 + i * 0.37) % 1;
          const dx = (i - 1) * rx * 0.4;
          const dy = b + R * 0.06 + p * R * 0.5;
          const s = R * 0.07;
          x.beginPath();
          x.moveTo(dx, dy - s * 1.4);
          x.quadraticCurveTo(dx - s * 1.4, dy + s * 0.6, dx, dy + s);
          x.quadraticCurveTo(dx + s * 1.4, dy + s * 0.6, dx, dy - s * 1.4);
          x.fillStyle = rgbaHex(pal.accent2, 1 - p);
          x.fill();
        }
      }
      break;
    }
    case "lumo": {
      const y0 = bottomY(k.critter, rx, ry, R) - R * 0.04;
      x.strokeStyle = pal.accent;
      x.lineWidth = R * 0.07;
      for (let i = 0; i < 4; i++) {
        const x0 = ((i - 1.5) / 1.5) * rx * 0.5;
        let len = R * 0.55, amp = R * 0.05, speed = 2.5, curl = 0;
        if (busy(k.state)) { amp = R * 0.09; speed = 8; }
        if (k.state === "error") { amp = R * 0.01; len = R * 0.6; }
        if (k.state === "sleeping") { len = R * 0.28; amp = R * 0.02; curl = (i < 2 ? -1 : 1) * R * 0.12; }
        x.beginPath();
        for (let j = 0; j <= 11; j++) {
          const f = j / 11;
          const px = x0 + Math.sin(j * 0.7 + now * speed + i) * amp * f + curl * f * f;
          const py = y0 + f * len;
          if (j === 0) x.moveTo(px, py); else x.lineTo(px, py);
        }
        x.stroke();
      }
      break;
    }
    case "tecla":
      break;
  }
  x.restore();
}

/** Drawn right after the body gradient, under the state tint (Tecla's key top). */
export function drawCritterSurfaceBase(x: CanvasRenderingContext2D, k: CritterCtx, body: Path2D, R: number, rx: number, ry: number) {
  if (k.critter !== "tecla") return;
  const pal = PALETTES.tecla;
  x.save();
  x.clip(body);
  x.globalAlpha *= 1 - k.morph;
  const fx = -rx * 0.82, fy = -ry * 0.88, fw = rx * 1.64, fh = ry * 1.36;
  const g = x.createLinearGradient(0, fy, 0, fy + fh);
  g.addColorStop(0, pal.accent);
  g.addColorStop(1, pal.accent2);
  x.fillStyle = g;
  const r = R * 0.28;
  x.beginPath();
  x.moveTo(fx + r, fy);
  x.arcTo(fx + fw, fy, fx + fw, fy + fh, r);
  x.arcTo(fx + fw, fy + fh, fx, fy + fh, r);
  x.arcTo(fx, fy + fh, fx, fy, r);
  x.arcTo(fx, fy, fx + fw, fy, r);
  x.closePath();
  x.fill();
  x.restore();
}

/** Drawn on the body after its shading (Bao's pleats, Lumo's and Tecla's highlights). */
export function drawCritterSurface(x: CanvasRenderingContext2D, k: CritterCtx, body: Path2D, R: number, rx: number, ry: number) {
  const alpha = Math.max(0, 1 - k.morph * 2);
  if (k.isMini || alpha <= 0.01) return;
  const pal = PALETTES[k.critter];
  x.save();
  x.clip(body);
  x.globalAlpha *= alpha;
  x.lineCap = "round";
  x.beginPath();
  switch (k.critter) {
    case "bao": {
      const top = headTop(k.critter, rx, ry, R);
      x.moveTo(-rx * 0.23, top + ry * 0.26);
      x.quadraticCurveTo(0, top - ry * 0.06, rx * 0.23, top + ry * 0.26);
      x.moveTo(-rx * 0.13, top + ry * 0.2);
      x.quadraticCurveTo(0, top + ry * 0.02, rx * 0.13, top + ry * 0.2);
      x.strokeStyle = pal.accent;
      x.lineWidth = R * 0.045;
      x.stroke();
      break;
    }
    case "lumo":
      x.moveTo(-rx * 0.7, -ry * 0.3);
      x.quadraticCurveTo(-rx * 0.62, -ry * 0.82, -rx * 0.22, -ry * 0.92);
      x.strokeStyle = "rgba(255,255,255,0.55)";
      x.lineWidth = R * 0.07;
      x.stroke();
      break;
    case "tecla":
      x.moveTo(-rx * 0.6, -ry * 0.7);
      x.lineTo(-rx * 0.22, -ry * 0.7);
      x.strokeStyle = "rgba(255,255,255,0.6)";
      x.lineWidth = R * 0.06;
      x.stroke();
      break;
    default:
      break;
  }
  x.restore();
}

function drawSprout(x: CanvasRenderingContext2D, k: CritterCtx, R: number, rx: number, ry: number, now: number) {
  const pal = PALETTES.pip;
  const base = headTop("pip", rx, ry, R) + R * 0.05;
  const bloom = k.state === "finished";
  const ay = base - R * 0.36;
  const tipY = bloom ? ay - R * 0.16 : ay;

  x.strokeStyle = pal.accent2;
  x.lineWidth = R * 0.065;
  x.beginPath();
  x.moveTo(0, base);
  x.lineTo(0, tipY);
  x.stroke();

  let angle = Math.sin(now * 1.5) * 0.06;
  if (busy(k.state)) angle = Math.sin(now * 10) * 0.25 - 0.1;
  if (k.state === "error" || k.state === "ratelimit") angle = 1.05;
  if (k.state === "sleeping") angle = -1.0;
  const wilted = k.state === "error" || k.state === "ratelimit";
  const colors = wilted ? ["#8DAA5E", "#9CB86A"] : [pal.accent, "#6CC47A"];

  [-1, 1].forEach((side, i) => {
    x.save();
    x.translate(0, ay);
    x.scale(side === -1 ? 1 : -1, 1);
    x.rotate(-angle);
    x.beginPath();
    x.moveTo(0, 0);
    x.bezierCurveTo(-R * 0.12, -R * 0.3, -R * 0.38, -R * 0.28, -R * 0.42, -R * 0.14);
    x.bezierCurveTo(-R * 0.4, -R * 0.02, -R * 0.16, R * 0.05, 0, 0);
    x.fillStyle = colors[i];
    x.fill();
    x.restore();
  });

  if (bloom) {
    const fy = tipY - R * 0.04;
    const pr = R * 0.065;
    x.fillStyle = "#FFD36E";
    for (let i = 0; i < 5; i++) {
      const a = (i / 5) * Math.PI * 2 - Math.PI / 2 + now * 0.3;
      x.beginPath();
      x.arc(Math.cos(a) * R * 0.08, fy + Math.sin(a) * R * 0.08, pr, 0, Math.PI * 2);
      x.fill();
    }
    x.fillStyle = "#F08A5D";
    x.beginPath();
    x.arc(0, fy, R * 0.055, 0, Math.PI * 2);
    x.fill();
  }
}
