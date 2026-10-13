import Foundation
import CoreGraphics
import SwiftUI

// The character the user picked (Settings → General → Character).
//
// Every character shares the engine: the same eyes, blush, badges, particles, hands and the
// mailbox morph. A character only brings its own silhouette (sampled by angle, so it still
// morphs into the upload box), its colours, and a few drawn extras that react to the state
// (Bao's steam, Pip's sprout, Nube's sun and rain, Lumo's tentacles, Tecla's key top).
// Its name is the one the interface uses ("Ask Lumo", "Hey Pip"): see botName().

/// The picked character's name, for the interface ("Ask Lumo", "Hey Pip").
@MainActor func botName() -> String { AppState.shared.critter.displayName }

enum Critter: String, CaseIterable, Identifiable, Sendable {
    case bao, pip, nube, lumo, tecla

    var id: String { rawValue }

    static let storageKey = "critter"
    static let fallback: Critter = .bao

    /// The saved choice, readable off the main actor (the wake word listens there).
    static var stored: Critter {
        Critter(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? fallback
    }

    var displayName: String {
        switch self {
        case .bao:   return "Bao"
        case .pip:   return "Pip"
        case .nube:  return "Nube"
        case .lumo:  return "Lumo"
        case .tecla: return "Tecla"
        }
    }

    var tagline: String {
        switch self {
        case .bao:   return L("A steamed bun that steams while it works")
        case .pip:   return L("A bean with a sprout that tells how things go")
        case .nube:  return L("A little cloud: rain on errors, sun when done")
        case .lumo:  return L("A glowing jellyfish that wiggles while it works")
        case .tecla: return L("A keycap that presses itself while it types")
        }
    }

    struct Palette {
        let top: CGColor        // body gradient, top-right
        let bottom: CGColor     // body gradient, bottom-left
        let ink: CGColor        // eyes
        let blush: (CGFloat, CGFloat, CGFloat)
        let accent: CGColor     // pleats, leaves, tentacles, key top
        let accent2: CGColor    // stem, second leaf, flower…
    }

    var palette: Palette {
        switch self {
        case .bao:
            return Palette(top: .from("#F8EDDC"), bottom: .from("#E2CDAE"), ink: .from("#3B2A1E"),
                           blush: (0.949, 0.627, 0.494), accent: .from("#D2B994"), accent2: .from("#FFFFFF"))
        case .pip:
            return Palette(top: .from("#C4E6A3"), bottom: .from("#93C46E"), ink: .from("#2E3B26"),
                           blush: (0.957, 0.604, 0.541), accent: .from("#5DB36B"), accent2: .from("#4E9A5A"))
        case .nube:
            return Palette(top: .from("#F5F7FF"), bottom: .from("#C9D4F2"), ink: .from("#2B3350"),
                           blush: (0.961, 0.639, 0.710), accent: .from("#FFD36E"), accent2: .from("#7FB2FF"))
        case .lumo:
            return Palette(top: .from("#D6CBFF"), bottom: .from("#AE9CF7"), ink: .from("#2E2357"),
                           blush: (0.976, 0.659, 0.831), accent: .from("#A996F5"), accent2: .from("#FFFFFF"))
        case .tecla:
            return Palette(top: .from("#5FBFA2"), bottom: .from("#3E957B"), ink: .from("#1F3D35"),
                           blush: (0.961, 0.620, 0.545), accent: .from("#A3ECD5"), accent2: .from("#86DCC0"))
        }
    }

    /// The palette in a colour of the user's (#156): two of the same character can tell
    /// apart which integration they handle. Keeps the eyes, blush and the extras' own colours.
    func palette(tinted c: CGColor) -> Palette {
        let base = palette
        let rgb = cgColorToTuple(c)
        func mix(_ t: (CGFloat, CGFloat, CGFloat), _ amount: CGFloat) -> CGColor {
            let m = mix3(rgb, t, amount)
            return CGColor(red: m.0, green: m.1, blue: m.2, alpha: 1)
        }
        let white: (CGFloat, CGFloat, CGFloat) = (1, 1, 1), black: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        switch self {
        case .tecla:
            return Palette(top: c, bottom: mix(black, 0.22), ink: base.ink, blush: base.blush,
                           accent: mix(white, 0.55), accent2: mix(white, 0.38))
        case .bao:
            return Palette(top: mix(white, 0.5), bottom: c, ink: base.ink, blush: base.blush,
                           accent: mix(black, 0.18), accent2: base.accent2)
        case .lumo:
            return Palette(top: mix(white, 0.45), bottom: c, ink: base.ink, blush: base.blush,
                           accent: mix(black, 0.1), accent2: base.accent2)
        case .pip, .nube:
            return Palette(top: mix(white, 0.5), bottom: c, ink: base.ink, blush: base.blush,
                           accent: base.accent, accent2: base.accent2)
        }
    }

    /// Colours offered for a character in charge of an integration (#156).
    static let tintChoices = ["#EF5B5B", "#F59E42", "#F5C842", "#5CC46A", "#3DBFB0", "#4F8FF0", "#9B7BF2", "#F07AB8"]

    // MARK: - Silhouette

    /// Signed power: keeps the sign, bends the magnitude.
    private func spow(_ v: CGFloat, _ e: CGFloat) -> CGFloat { v >= 0 ? pow(v, e) : -pow(-v, e) }

    /// Point on the outline in direction `a` (radians, y down: sin > 0 is the bottom half),
    /// for a body of half-size rx × ry. Sampled by angle like Mochi's superellipse, so the
    /// upload morph can lerp every point to the mailbox.
    func outline(a: CGFloat, rx: CGFloat, ry: CGFloat, R: CGFloat) -> CGPoint {
        let ca = cos(a), sa = sin(a)
        switch self {
        case .bao:
            // Round dome, flat bottom.
            let x = rx * 0.98 * spow(ca, 0.8)
            let y = sa < 0 ? ry * 1.02 * spow(sa, 0.9) : ry * 0.62 * spow(sa, 0.35)
            return CGPoint(x: x, y: y + ry * 0.08)

        case .pip:
            // Bean: an ellipse with a soft dent on top, lowered to leave room for the sprout.
            let x = rx * 0.96 * spow(ca, 0.85)
            var y = ry * 0.86 * spow(sa, 0.85)
            if sa < 0 {
                let dent: CGFloat = exp(-pow(ca / 0.35, 2))
                y += ry * 0.14 * dent * (-sa)
            }
            return CGPoint(x: x, y: y + ry * 0.12)

        case .nube:
            // A flat-bottomed pill with three puffs on top: the farthest hit along the ray
            // among those shapes (in units of rx × ry).
            let pill = rrPointShared(ca: ca, sa: sa, W: 0.98, H: 0.62, cr: 0.45)
            var best = hypot(pill.x, pill.y)
            for (px, py, r) in [(-0.52, -0.1, 0.5), (0.02, -0.35, 0.62), (0.56, -0.05, 0.46)] as [(CGFloat, CGFloat, CGFloat)] {
                let dc = ca * px + sa * py
                let disc = dc * dc - (px * px + py * py - r * r)
                if disc >= 0 { best = max(best, dc + sqrt(disc)) }
            }
            return CGPoint(x: best * ca * rx, y: best * sa * ry + ry * 0.05)

        case .lumo:
            // Dome with a scalloped hem.
            let x = rx * 0.96 * spow(ca, 0.9)
            let y: CGFloat
            if sa < 0 {
                y = ry * 1.12 * spow(sa, 0.85)
            } else {
                let hem: CGFloat = 0.30 * pow(sa, 0.5)
                let scallop: CGFloat = 0.12 * abs(sin(2 * CGFloat.pi * ca)) * sa
                y = ry * (hem + scallop)
            }
            return CGPoint(x: x, y: y + ry * 0.2)

        case .tecla:
            // A keycap: rounded square.
            return rrPointShared(ca: ca, sa: sa, W: rx * 0.97, H: ry * 0.92, cr: R * 0.36)
        }
    }

    /// Each character's eyes: rounder, taller or narrower than the shared ones.
    var eyeAspect: (w: CGFloat, h: CGFloat) {
        switch self {
        case .bao:   return (1.05, 0.92)
        case .pip:   return (0.88, 1.12)
        case .nube:  return (1.0, 1.0)
        case .lumo:  return (0.85, 1.18)
        case .tecla: return (1.0, 0.86)
        }
    }

    /// How far the eyes and blush sit above the shared ones, in units of ry (Lumo's face is up in its dome).
    var faceLift: CGFloat { self == .lumo ? 0.3 : 0 }

    /// Where the top of the head is (used to anchor Pip's sprout and Bao's steam).
    func headTop(rx: CGFloat, ry: CGFloat, R: CGFloat) -> CGFloat {
        outline(a: .pi * 1.5, rx: rx, ry: ry, R: R).y
    }

    /// Where the bottom is (Lumo's tentacles, Nube's rain).
    func bottom(rx: CGFloat, ry: CGFloat, R: CGFloat) -> CGFloat {
        outline(a: .pi * 0.5, rx: rx, ry: ry, R: R).y
    }
}

/// Ray / rounded-rect intersection (same maths as BotEngine.rrPoint, usable off the engine).
func rrPointShared(ca: CGFloat, sa: CGFloat, W: CGFloat, H: CGFloat, cr: CGFloat) -> CGPoint {
    let eps: CGFloat = 1e-6
    let kx: CGFloat = ca >= 0 ? 1 : -1
    let ky: CGFloat = sa >= 0 ? 1 : -1
    let cx = kx * (W - cr)
    let cy = ky * (H - cr)
    let dot  = ca * cx + sa * cy
    let disc = dot * dot - (cx*cx + cy*cy - cr*cr)
    if disc >= 0 {
        let t = dot + sqrt(disc)
        if t > eps {
            let px = ca * t, py = sa * t
            if abs(px) >= W - cr - eps && abs(py) >= H - cr - eps { return CGPoint(x: px, y: py) }
        }
    }
    if abs(sa) > eps {
        let t = (ky * H) / sa
        if t > eps {
            let x = ca * t
            if abs(x) <= W - cr + eps { return CGPoint(x: x, y: ky * H) }
        }
    }
    if abs(ca) > eps {
        let t = (kx * W) / ca
        if t > eps {
            let y = sa * t
            if abs(y) <= H - cr + eps { return CGPoint(x: kx * W, y: y) }
        }
    }
    return CGPoint(x: ca * W, y: sa * H)
}

// MARK: - Drawn extras

@MainActor
extension BotEngine {

    private var critterTime: CGFloat { CGFloat(CACurrentMediaTime()) }

    /// How much the extras show: they fade out while morphing into the mailbox.
    private var extrasAlpha: Double { Double(max(0, 1 - morph * 2)) }

    private var isBusy: Bool { state == .working || state == .thinking || state == .searching }

    /// Tecla bobs down like a pressed key while busy. Applied to the body context before drawing.
    func critterPress(ctx: inout GraphicsContext, R: CGFloat) {
        guard critter == .tecla, isBusy, !isMini, morph < 0.5 else { return }
        let p = pow(max(0, sin(critterTime * 11)), 3)
        ctx.translateBy(x: 0, y: p * R * 0.05)
        ctx.scaleBy(x: 1, y: 1 - p * 0.06)
    }

    /// Extras behind the body (sprout, tentacles, sun, steam, rain).
    func drawCritterBack(ctx: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard !isMini, extrasAlpha > 0.01 else { return }
        var c = ctx
        c.opacity = extrasAlpha
        let pal = palette
        let t = critterTime
        switch critter {
        case .tecla:
            break

        case .bao:
            guard isBusy else { return }
            let top = critter.headTop(rx: rx, ry: ry, R: R)
            for i in 0..<3 {
                let x0 = CGFloat(i - 1) * rx * 0.37
                let p = (t * 0.6 + CGFloat(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let y0 = top - R * 0.08 - p * R * 0.35
                var wisp = Path()
                for k in 0...10 {
                    let pt = CGPoint(x: x0 + sin(CGFloat(k) * 0.9 + t * 4 + CGFloat(i)) * R * 0.06,
                                     y: y0 - CGFloat(k) * R * 0.04)
                    if k == 0 { wisp.move(to: pt) } else { wisp.addLine(to: pt) }
                }
                c.stroke(wisp, with: .color(Color(cgColor: pal.accent2).opacity(Double(sin(p * .pi)) * 0.55)),
                         style: StrokeStyle(lineWidth: R * 0.06, lineCap: .round, lineJoin: .round))
            }

        case .pip:
            drawSprout(ctx: c, R: R, rx: rx, ry: ry, t: t)

        case .nube:
            if state == .finished {
                let sun = CGPoint(x: -rx * 0.62, y: -ry * 0.72)
                let sr = R * 0.26
                for k in 0..<8 {
                    let a = CGFloat(k) / 8 * .pi * 2 + t * 0.4
                    var ray = Path()
                    ray.move(to: CGPoint(x: sun.x + cos(a) * sr * 1.3, y: sun.y + sin(a) * sr * 1.3))
                    ray.addLine(to: CGPoint(x: sun.x + cos(a) * sr * 1.65, y: sun.y + sin(a) * sr * 1.65))
                    c.stroke(ray, with: .color(Color(cgColor: pal.accent)),
                             style: StrokeStyle(lineWidth: R * 0.06, lineCap: .round))
                }
                c.fill(Path(ellipseIn: CGRect(x: sun.x - sr, y: sun.y - sr, width: sr * 2, height: sr * 2)),
                       with: .color(Color(cgColor: pal.accent)))
            }
            if state == .error || state == .ratelimit {
                let bottom = critter.bottom(rx: rx, ry: ry, R: R)
                for i in 0..<3 {
                    let p = (t * 1.2 + CGFloat(i) * 0.37).truncatingRemainder(dividingBy: 1)
                    let x = CGFloat(i - 1) * rx * 0.4
                    let y = bottom + R * 0.06 + p * R * 0.5
                    let s = R * 0.07
                    var drop = Path()
                    drop.move(to: CGPoint(x: x, y: y - s * 1.4))
                    drop.addQuadCurve(to: CGPoint(x: x, y: y + s), control: CGPoint(x: x - s * 1.4, y: y + s * 0.6))
                    drop.addQuadCurve(to: CGPoint(x: x, y: y - s * 1.4), control: CGPoint(x: x + s * 1.4, y: y + s * 0.6))
                    c.fill(drop, with: .color(Color(cgColor: pal.accent2).opacity(Double(1 - p))))
                }
            }

        case .lumo:
            let y0 = critter.bottom(rx: rx, ry: ry, R: R) - R * 0.04
            let busy = isBusy
            for i in 0..<4 {
                let x0 = (CGFloat(i) - 1.5) / 1.5 * rx * 0.5
                var len = R * 0.55, amp = R * 0.05, speed: CGFloat = 2.5, curl: CGFloat = 0
                if busy { amp = R * 0.09; speed = 8 }
                if state == .error { amp = R * 0.01; len = R * 0.6 }
                if state == .sleeping { len = R * 0.28; amp = R * 0.02; curl = (i < 2 ? -1 : 1) * R * 0.12 }
                var tent = Path()
                for k in 0...11 {
                    let f = CGFloat(k) / 11
                    let pt = CGPoint(x: x0 + sin(CGFloat(k) * 0.7 + t * speed + CGFloat(i)) * amp * f + curl * f * f,
                                     y: y0 + f * len)
                    if k == 0 { tent.move(to: pt) } else { tent.addLine(to: pt) }
                }
                c.stroke(tent, with: .color(Color(cgColor: pal.accent)),
                         style: StrokeStyle(lineWidth: R * 0.07, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Drawn right after the body gradient, under the state tint (Tecla's key top).
    func drawCritterSurfaceBase(ctx: GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard critter == .tecla else { return }
        var c = ctx
        c.clip(to: path)
        c.opacity = Double(1 - morph)
        let pal = palette
        let face = CGRect(x: -rx * 0.82, y: -ry * 0.88, width: rx * 1.64, height: ry * 1.36)
        c.fill(Path(roundedRect: face, cornerRadius: R * 0.28),
               with: .linearGradient(Gradient(colors: [Color(cgColor: pal.accent), Color(cgColor: pal.accent2)]),
                                     startPoint: CGPoint(x: 0, y: face.minY), endPoint: CGPoint(x: 0, y: face.maxY)))
    }

    /// Drawn on the body after its shading (Bao's pleats, Lumo's and Tecla's highlights).
    func drawCritterSurface(ctx: GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard !isMini, extrasAlpha > 0.01 else { return }
        var c = ctx
        c.clip(to: path)
        c.opacity = extrasAlpha
        let pal = palette
        switch critter {
        case .bao:
            let top = critter.headTop(rx: rx, ry: ry, R: R)
            var pleats = Path()
            pleats.move(to: CGPoint(x: -rx * 0.23, y: top + ry * 0.26))
            pleats.addQuadCurve(to: CGPoint(x: rx * 0.23, y: top + ry * 0.26), control: CGPoint(x: 0, y: top - ry * 0.06))
            pleats.move(to: CGPoint(x: -rx * 0.13, y: top + ry * 0.2))
            pleats.addQuadCurve(to: CGPoint(x: rx * 0.13, y: top + ry * 0.2), control: CGPoint(x: 0, y: top + ry * 0.02))
            c.stroke(pleats, with: .color(Color(cgColor: pal.accent)),
                     style: StrokeStyle(lineWidth: R * 0.045, lineCap: .round))
        case .lumo:
            var hl = Path()
            hl.move(to: CGPoint(x: -rx * 0.7, y: -ry * 0.3))
            hl.addQuadCurve(to: CGPoint(x: -rx * 0.22, y: -ry * 0.92), control: CGPoint(x: -rx * 0.62, y: -ry * 0.82))
            c.stroke(hl, with: .color(Color.white.opacity(0.55)),
                     style: StrokeStyle(lineWidth: R * 0.07, lineCap: .round))
        case .tecla:
            var hl = Path()
            hl.move(to: CGPoint(x: -rx * 0.6, y: -ry * 0.7))
            hl.addLine(to: CGPoint(x: -rx * 0.22, y: -ry * 0.7))
            c.stroke(hl, with: .color(Color.white.opacity(0.6)),
                     style: StrokeStyle(lineWidth: R * 0.06, lineCap: .round))
        case .pip, .nube:
            break
        }
    }

    // MARK: Pip's sprout

    private func drawSprout(ctx: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, t: CGFloat) {
        let pal = palette
        let base = critter.headTop(rx: rx, ry: ry, R: R) + R * 0.05
        let bloom = state == .finished
        let anchor = CGPoint(x: 0, y: base - R * 0.36)
        let tip = bloom ? CGPoint(x: 0, y: anchor.y - R * 0.16) : anchor

        var stem = Path()
        stem.move(to: CGPoint(x: 0, y: base))
        stem.addLine(to: tip)
        ctx.stroke(stem, with: .color(Color(cgColor: pal.accent2)),
                   style: StrokeStyle(lineWidth: R * 0.065, lineCap: .round))

        // Leaf angle by state: sway, wiggle, droop, fold.
        var angle = sin(t * 1.5) * 0.06
        if isBusy { angle = sin(t * 10) * 0.25 - 0.1 }
        if state == .error || state == .ratelimit { angle = 1.05 }
        if state == .sleeping { angle = -1.0 }
        let wilted = state == .error || state == .ratelimit
        let colors = wilted ? [Color(cgColor: .from("#8DAA5E")), Color(cgColor: .from("#9CB86A"))]
                            : [Color(cgColor: pal.accent), Color(cgColor: .from("#6CC47A"))]

        for (i, side) in [CGFloat(-1), 1].enumerated() {
            var leaf = Path()
            leaf.move(to: .zero)
            leaf.addCurve(to: CGPoint(x: -R * 0.42, y: -R * 0.14),
                          control1: CGPoint(x: -R * 0.12, y: -R * 0.30),
                          control2: CGPoint(x: -R * 0.38, y: -R * 0.28))
            leaf.addCurve(to: .zero,
                          control1: CGPoint(x: -R * 0.40, y: -R * 0.02),
                          control2: CGPoint(x: -R * 0.16, y: R * 0.05))
            let tf = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                .scaledBy(x: side == -1 ? 1 : -1, y: 1)
                .rotated(by: -angle)
            ctx.fill(leaf.applying(tf), with: .color(colors[i]))
        }

        if bloom {
            let fc = CGPoint(x: 0, y: tip.y - R * 0.04)
            let pr = R * 0.065
            for k in 0..<5 {
                let a = CGFloat(k) / 5 * .pi * 2 - .pi / 2 + t * 0.3
                let pc = CGPoint(x: fc.x + cos(a) * R * 0.08, y: fc.y + sin(a) * R * 0.08)
                ctx.fill(Path(ellipseIn: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2)),
                         with: .color(Color(cgColor: .from("#FFD36E"))))
            }
            let cr = R * 0.055
            ctx.fill(Path(ellipseIn: CGRect(x: fc.x - cr, y: fc.y - cr, width: cr * 2, height: cr * 2)),
                     with: .color(Color(cgColor: .from("#F08A5D"))))
        }
    }
}

// MARK: - Face: mouth, eye shine, brows

@MainActor
extension BotEngine {

    private enum Mouth { case smile, open, grin, wobble, flat, tiny }

    private func mouth(for shape: EyeShape) -> Mouth {
        switch state {
        case .finished: return .grin
        case .approval: return .open
        case .question: return .open
        case .error, .dizzy: return .wobble
        case .ratelimit: return .flat
        case .sleeping: return .tiny
        default: break
        }
        switch shape {
        case .happy, .heart, .star, .wink: return .grin
        case .wide: return .open
        case .spiral: return .wobble
        case .flat, .tired, .line: return .flat
        case .closed: return .tiny
        default: return .smile
        }
    }

    /// The mouth, under the eyes, following where the head looks. Fades out into the mailbox.
    func drawMouth(ctx: GraphicsContext, shape: EyeShape, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        var pitchNow = MochiConst.eyeP + pitch + roll
        pitchNow = ((pitchNow + .pi).truncatingRemainder(dividingBy: .pi * 2) + .pi * 2)
            .truncatingRemainder(dividingBy: .pi * 2) - .pi
        let cp = cos(pitchNow)
        let facing = cos(yaw) * cp
        guard facing > 0.3 else { return }

        let mx = sin(yaw) * cp * rx
        let my = -sin(pitchNow) * ry - critter.faceLift * ry + R * 0.24
        var c = ctx
        c.translateBy(x: mx, y: my)
        c.scaleBy(x: max(0.3, cos(yaw)), y: max(0.3, cp))
        c.opacity = Double(max(0, 1 - morph / 0.3))
        let ink = Color(cgColor: palette.ink)
        let w = R * 0.1
        let line = StrokeStyle(lineWidth: R * 0.05, lineCap: .round, lineJoin: .round)

        switch mouth(for: shape) {
        case .smile:
            var p = Path()
            p.move(to: CGPoint(x: -w, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: 0, y: w * 0.95))
            c.stroke(p, with: .color(ink), style: line)
        case .open:
            let s: CGFloat = state == .question ? 0.8 : 1
            c.fill(Path(ellipseIn: CGRect(x: -w * 0.5 * s, y: -w * 0.2, width: w * s, height: w * 1.25 * s)),
                   with: .color(ink))
        case .grin:
            var p = Path()
            p.move(to: CGPoint(x: -w * 1.25, y: -w * 0.15))
            p.addQuadCurve(to: CGPoint(x: w * 1.25, y: -w * 0.15), control: CGPoint(x: 0, y: w * 1.7))
            p.closeSubpath()
            c.fill(p, with: .color(ink))
            var tongue = c
            tongue.clip(to: p)
            tongue.fill(Path(ellipseIn: CGRect(x: -w * 0.55, y: w * 0.35, width: w * 1.1, height: w * 0.8)),
                        with: .color(Color(red: 0.98, green: 0.47, blue: 0.53)))
        case .wobble:
            var p = Path()
            for i in 0...12 {
                let t = CGFloat(i) / 12
                let pt = CGPoint(x: -w * 1.1 + t * w * 2.2, y: sin(t * .pi * 3) * w * 0.25)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            c.stroke(p, with: .color(ink), style: line)
        case .flat:
            var p = Path()
            p.move(to: CGPoint(x: -w * 0.75, y: w * 0.15))
            p.addLine(to: CGPoint(x: w * 0.75, y: w * 0.15))
            c.stroke(p, with: .color(ink), style: line)
        case .tiny:
            c.fill(Path(ellipseIn: CGRect(x: -w * 0.32, y: 0, width: w * 0.64, height: w * 0.7)),
                   with: .color(ink.opacity(0.85)))
        }
    }

    /// A shine in open eyes, and brows for the strong states (cross, worried, puzzled).
    /// Drawn in the eye's own coordinates (already placed and squashed with the head).
    func drawEyeExtras(ctx: inout GraphicsContext, shape: EyeShape, w: CGFloat, h: CGFloat, sd: CGFloat) {
        if (shape == .pill || shape == .wide || shape == .dot) && open > 0.5 {
            let r = w * 0.2
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.12 - r, y: -h * 0.22 - r, width: r * 2, height: r * 2)),
                     with: .color(Color.white.opacity(0.9)))
        }

        // Brows: the inner end (towards the other eye) is at x = -sd.
        let innerY: CGFloat, outerY: CGFloat
        switch state {
        case .error:                  innerY = -h * 0.72; outerY = -h * 1.0    // cross
        case .approval, .ratelimit:   innerY = -h * 1.02; outerY = -h * 0.82   // worried
        case .question:
            guard sd > 0 else { return }                                      // one raised brow
            innerY = -h * 1.08; outerY = -h * 1.0
        default: return
        }
        var brow = Path()
        brow.move(to: CGPoint(x: -sd * w * 0.62, y: innerY))
        brow.addLine(to: CGPoint(x: sd * w * 0.62, y: outerY))
        ctx.stroke(brow, with: .color(Color(cgColor: palette.ink)),
                   style: StrokeStyle(lineWidth: w * 0.3, lineCap: .round))
    }
}
