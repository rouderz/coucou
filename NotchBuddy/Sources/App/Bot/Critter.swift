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

    /// How far the eyes and blush sit above Mochi's, in units of ry (Lumo's face is up in its dome).
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
        let pal = critter.palette
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
        let pal = critter.palette
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
        let pal = critter.palette
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
        let pal = critter.palette
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
