// Themes: Dark (the original look), Light, System and popular palettes. Same table as
// NotchBuddy/Sources/App/Theme.swift — keep both in step.
//
// A theme only re-points the CSS colour tokens (--ink, --dim, --card, …) of the island and the
// Settings window. Brand colours (pills), status colours (red / amber / green) and Mochi stay.

export interface ThemePalette {
  id: string;
  name: string;
  isLight: boolean;
  bg: string;
  card: string;
  ink: string;
  ink2: string;
  dim: string;
  dim3: string;
  accent: string;
}

const p = (
  id: string, name: string, isLight: boolean,
  bg: string, card: string, ink: string, ink2: string, dim: string, dim3: string, accent: string,
): ThemePalette => ({ id, name, isLight, bg, card, ink, ink2, dim, dim3, accent });

export const DARK = p("dark", "Dark", false, "#0B0C0E", "#141518", "#F5F6F8", "#C5C8CD", "#8E939C", "#6B7079", "#A78BFA");
export const LIGHT = p("light", "Light", true, "#F2F2F5", "#FFFFFF", "#1D1D1F", "#3A3A3C", "#636366", "#8E8E93", "#7C3AED");

export const THEMES: readonly ThemePalette[] = [
  DARK,
  LIGHT,
  p("dracula", "Dracula", false, "#21222C", "#282A36", "#F8F8F2", "#E2E2DC", "#A4AED6", "#6272A4", "#BD93F9"),
  p("nord", "Nord", false, "#2E3440", "#3B4252", "#ECEFF4", "#E5E9F0", "#C3CAD6", "#99A2B3", "#88C0D0"),
  p("catppuccin-mocha", "Catppuccin Mocha", false, "#181825", "#1E1E2E", "#CDD6F4", "#BAC2DE", "#A6ADC8", "#7F849C", "#CBA6F7"),
  p("catppuccin-latte", "Catppuccin Latte", true, "#E6E9EF", "#EFF1F5", "#4C4F69", "#5C5F77", "#5F6278", "#8C8FA1", "#8839EF"),
  p("solarized-dark", "Solarized Dark", false, "#002B36", "#073642", "#EEE8D5", "#B7C0C0", "#93A1A1", "#839496", "#268BD2"),
  p("solarized-light", "Solarized Light", true, "#EEE8D5", "#FDF6E3", "#073642", "#3D545B", "#4F6269", "#839496", "#268BD2"),
  p("tokyo-night", "Tokyo Night", false, "#16161E", "#1A1B26", "#C0CAF5", "#A9B1D6", "#9AA5CE", "#737AA2", "#7AA2F7"),
  p("gruvbox-dark", "Gruvbox Dark", false, "#1D2021", "#282828", "#EBDBB2", "#D5C4A1", "#BDAE93", "#A89984", "#FABD2F"),
  p("one-dark", "One Dark", false, "#21252B", "#282C34", "#D7DAE0", "#ABB2BF", "#9DA5B4", "#7F848E", "#61AFEF"),
];

/** "system", or one of THEMES' ids; unknown ids fall back to Dark. */
export function palette(id: string | undefined, systemIsDark: boolean): ThemePalette {
  if (id === "system") return systemIsDark ? DARK : LIGHT;
  return THEMES.find((t) => t.id === id) ?? DARK;
}

/**
 * The CSS tokens to set for a theme. Dark returns nothing: the stylesheets' own values are
 * the original design and stay untouched.
 */
export function themeVars(t: ThemePalette): Record<string, string> {
  if (t.id === DARK.id) return {};
  const hair = t.isLight ? "rgba(0, 0, 0, 0.08)" : "rgba(255, 255, 255, 0.06)";
  return {
    "--ink": t.ink, "--ink-2": t.ink, "--ink-3": t.ink2,
    "--dim": t.dim, "--dim-2": t.dim, "--dim-3": t.dim3, "--dim-4": t.dim3, "--dim-5": t.dim3,
    "--card": t.card, "--card-flat": t.bg, "--tab-on": t.card, "--bg": t.bg,
    "--hairline": hair, "--accent": t.accent, "--island": t.bg,
  };
}

/** Sets (or clears) the tokens on a window's root element. */
export function applyTheme(root: HTMLElement, id: string | undefined, systemIsDark: boolean) {
  const t = palette(id, systemIsDark);
  for (const name of ALL_VARS) root.style.removeProperty(name);
  for (const [name, value] of Object.entries(themeVars(t))) root.style.setProperty(name, value);
  root.dataset.theme = t.id;
  root.style.colorScheme = t.isLight ? "light" : "dark";
}

const ALL_VARS = Object.keys(themeVars(LIGHT));

// WCAG contrast, for the tests.
export function luminance(hex: string): number {
  const v = parseInt(hex.replace("#", ""), 16);
  const lin = (c: number) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin((v >> 16) & 255) + 0.7152 * lin((v >> 8) & 255) + 0.0722 * lin(v & 255);
}

export function contrast(a: string, b: string): number {
  const [x, y] = [luminance(a), luminance(b)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}
