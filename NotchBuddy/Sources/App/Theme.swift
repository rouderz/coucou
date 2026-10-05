import SwiftUI

// Themes: Dark (the original look), Light, System, and popular palettes. Same table as
// windows/src/core/themes.ts — keep both in step.
//
// The island's views use a handful of neutral hex values (text, secondary text, card, …).
// `Color(hex:)` swaps exactly those for the active theme's colour, so every view follows the
// theme without touching each one. Brand colours (pills), status colours (red / amber / green)
// and Mochi are never swapped. The island's black shell stays black: it has to blend with the
// hardware notch.
// (Superseded: the whole island now takes the theme's background; only Dark keeps pure black.)

struct ThemePalette: Equatable, Sendable {
    let id: String
    let name: String
    let isLight: Bool
    let bg: String       // the deepest surface (behind cards)
    let card: String     // cards, rows, chat
    let ink: String      // primary text
    let ink2: String     // secondary text
    let dim: String      // labels, hints
    let dim3: String     // tertiary (timestamps, disabled)
    let accent: String   // links, selection, the chat's accent
}

enum Theme {
    static let dark = ThemePalette(id: "dark", name: "Dark", isLight: false, bg: "#0B0C0E", card: "#141518",
                                   ink: "#F5F6F8", ink2: "#C5C8CD", dim: "#8E939C", dim3: "#6B7079", accent: "#A78BFA")
    static let light = ThemePalette(id: "light", name: "Light", isLight: true, bg: "#F2F2F5", card: "#FFFFFF",
                                    ink: "#1D1D1F", ink2: "#3A3A3C", dim: "#636366", dim3: "#8E8E93", accent: "#7C3AED")

    /// Every theme the user can pick ("system" follows the Mac's appearance).
    static let all: [ThemePalette] = [
        dark, light,
        ThemePalette(id: "dracula", name: "Dracula", isLight: false, bg: "#21222C", card: "#282A36",
                     ink: "#F8F8F2", ink2: "#E2E2DC", dim: "#A4AED6", dim3: "#6272A4", accent: "#BD93F9"),
        ThemePalette(id: "nord", name: "Nord", isLight: false, bg: "#2E3440", card: "#3B4252",
                     ink: "#ECEFF4", ink2: "#E5E9F0", dim: "#C3CAD6", dim3: "#99A2B3", accent: "#88C0D0"),
        ThemePalette(id: "catppuccin-mocha", name: "Catppuccin Mocha", isLight: false, bg: "#181825", card: "#1E1E2E",
                     ink: "#CDD6F4", ink2: "#BAC2DE", dim: "#A6ADC8", dim3: "#7F849C", accent: "#CBA6F7"),
        ThemePalette(id: "catppuccin-latte", name: "Catppuccin Latte", isLight: true, bg: "#E6E9EF", card: "#EFF1F5",
                     ink: "#4C4F69", ink2: "#5C5F77", dim: "#5F6278", dim3: "#8C8FA1", accent: "#8839EF"),
        ThemePalette(id: "solarized-dark", name: "Solarized Dark", isLight: false, bg: "#002B36", card: "#073642",
                     ink: "#EEE8D5", ink2: "#B7C0C0", dim: "#93A1A1", dim3: "#839496", accent: "#268BD2"),
        ThemePalette(id: "solarized-light", name: "Solarized Light", isLight: true, bg: "#EEE8D5", card: "#FDF6E3",
                     ink: "#073642", ink2: "#3D545B", dim: "#4F6269", dim3: "#839496", accent: "#268BD2"),
        ThemePalette(id: "tokyo-night", name: "Tokyo Night", isLight: false, bg: "#16161E", card: "#1A1B26",
                     ink: "#C0CAF5", ink2: "#A9B1D6", dim: "#9AA5CE", dim3: "#737AA2", accent: "#7AA2F7"),
        ThemePalette(id: "gruvbox-dark", name: "Gruvbox Dark", isLight: false, bg: "#1D2021", card: "#282828",
                     ink: "#EBDBB2", ink2: "#D5C4A1", dim: "#BDAE93", dim3: "#A89984", accent: "#FABD2F"),
        ThemePalette(id: "one-dark", name: "One Dark", isLight: false, bg: "#21252B", card: "#282C34",
                     ink: "#D7DAE0", ink2: "#ABB2BF", dim: "#9DA5B4", dim3: "#7F848E", accent: "#61AFEF"),
    ]

    /// "system", or one of `all`'s ids. Unknown ids fall back to Dark.
    static func palette(for id: String, systemIsDark: Bool) -> ThemePalette {
        if id == "system" { return systemIsDark ? dark : light }
        return all.first { $0.id == id } ?? dark
    }

    /// The original neutral each role used, in every spelling the views use.
    nonisolated(unsafe) static let roles: [String: KeyPath<ThemePalette, String>] = [
        "F5F6F8": \.ink, "F1F2F4": \.ink, "E6E8EB": \.ink, "F2F3F5": \.ink, "EDEDEF": \.ink, "E8E9EC": \.ink,
        "D5D7DB": \.ink2,
        "C5C8CD": \.ink2, "B0B5BE": \.ink2, "A9ADB5": \.ink2, "A3A8B0": \.ink2, "B9BDC4": \.ink2, "C4C5CA": \.ink2,
        "8E939C": \.dim, "9398A1": \.dim, "7C818A": \.dim, "80858E": \.dim, "6E737C": \.dim,
        "6B7079": \.dim3, "5F646D": \.dim3, "4B5563": \.dim3, "4D5159": \.dim3, "454850": \.dim3,
        "141518": \.card, "1D1F23": \.card, "16171A": \.card, "252830": \.card,
        "0B0C0E": \.bg, "0E0F11": \.bg, "0E0F12": \.bg,
        "A78BFA": \.accent,
    ]

    /// Set on the main thread when the setting or the system appearance changes; read by Color(hex:).
    nonisolated(unsafe) static var current: ThemePalette = dark

    /// The hex to draw for a hex the views asked for.
    static func resolve(_ hex: String, in palette: ThemePalette) -> String {
        // Dark is the original design: every grey stays exactly as the views wrote it.
        if palette.id == dark.id { return hex }
        let key = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard let role = roles[key] else { return hex }
        return palette[keyPath: role]
    }

    // MARK: Contrast (WCAG), for the tests

    static func luminance(_ hex: String) -> Double {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0
        func lin(_ c: UInt64) -> Double {
            let s = Double(c) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((v >> 16) & 0xFF) + 0.7152 * lin((v >> 8) & 0xFF) + 0.0722 * lin(v & 0xFF)
    }

    static func contrast(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
