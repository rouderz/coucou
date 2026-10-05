import Foundation
import CoreGraphics
import SwiftUI

@MainActor
extension BotEngine {
    // MARK: - Update (called every frame from TimelineView)

    func update(dt: Double) {
        let now = CACurrentMediaTime()
        let dtCG = CGFloat(dt)

        // Process tweens
        for key in tweens.keys {
            guard var tw = tweens[key] else { continue }
            let k = tw.keys[tw.keyIndex]
            let elapsed = now * 1000 - tw.startTime
            let p = min(1, max(0, CGFloat(elapsed) / k.duration))
            let val = tw.from + (k.target - tw.from) * k.ease(p)
            setProperty(key, value: val)

            if p >= 1 {
                tw.from = k.target
                tw.keyIndex += 1
                tw.startTime = now * 1000
                if tw.keyIndex >= tw.keys.count {
                    tweens.removeValue(forKey: key)
                    locks.remove(key)
                    tw.onComplete?()
                } else {
                    tweens[key] = tw
                }
            } else {
                tweens[key] = tw
            }
        }

        // Compute look targets
        let t = CGFloat(now - t0)
        var ty: CGFloat = lookX * 0.62
        var tp: CGFloat = lookY * 0.5

        if let fixedLook = cfg.look {
            ty = ty * 0.35 + fixedLook.x * 0.55
            tp = tp * 0.3  + fixedLook.y * 0.5
        }
        if cfg.scans {
            ty = sin(t * 2.6) * 0.6
            tp = -0.06
        }
        if state == .sleeping { ty = 0; tp = -0.14 }
        if state == .dizzy    { ty = sin(t * 9) * 0.25 }

        // Mini bots: override look with random wandering (never follows mouse)
        if isMini && cfg.look == nil && !cfg.scans && state != .sleeping && state != .dizzy {
            if now > miniLookNextTime {
                miniLookTarget = CGPoint(
                    x: CGFloat.random(in: -0.88...0.88),
                    y: CGFloat.random(in: -0.55...0.45)
                )
                miniLookNextTime = now + Double.random(in: 0.5...2.0)
            }
            ty = miniLookTarget.x * 0.62
            tp = miniLookTarget.y * 0.5
        }

        tgYaw   = ty
        tgPitch = tp
        tgTilt  = cfg.tilt

        // Body sway during greeting wave
        if now > waveStart && now < waveUntil {
            let wt = CGFloat(now - waveStart)
            tgTilt = -0.06 + sin(2 * .pi * 1.2 * wt) * 0.07
        }

        let bounce = cfg.bounces ? -abs(sin(t * 5.2)) * 0.07 : CGFloat(0)
        // oy tween can override if not locked
        if !locks.contains("oy") { oy += (bounce - oy) * CGFloat(1 - pow(0.0008, dt)) }

        // Dance (#117): only the main Mochi, only idle, never while it's a mailbox. Eased in and
        // out (~0.3 s) so starting or pausing the music never makes it jump.
        let danceOn = dancing && !isMini && state == .idle && morph < 0.05
        let danceTarget: CGFloat = danceOn ? 1 : 0
        danceAmt += (danceTarget - danceAmt) * CGFloat(1 - pow(0.02, dt))
        if !danceOn && danceAmt < 0.001 { danceAmt = 0 }
        dancePose = MochiDance.pose(at: now, amount: danceAmt)

        if cfg.breathes {
            let amp: CGFloat = isMini ? 0.07 : 0.035
            tgSy = 1 + sin(t * 1.8) * amp
            tgSx = 1 - sin(t * 1.8) * amp * 0.57
        } else if isMini {
            // Subtle idle pulse (unique phase per engine via t0)
            tgSy = 1 + sin(t * 2.2) * 0.04
            tgSx = 1 - sin(t * 2.2) * 0.02
        } else {
            tgSy = 1; tgSx = 1
        }

        // Mini bots: periodic dramatic behaviors
        if isMini && now > miniNextBehavior {
            doMiniBehaviorLoop()
        }

        // Smooth look
        let kLook = CGFloat(1 - pow(0.0025, dt))
        let kGen  = CGFloat(1 - pow(0.0008, dt))

        if !locks.contains("yaw")   { yaw   += (tgYaw   - yaw)   * kLook }
        if !locks.contains("pitch") { pitch += (tgPitch  - pitch) * kLook }
        if !locks.contains("tilt")  { tilt  += (tgTilt   - tilt)  * kGen  }
        if !locks.contains("sy")    { sy    += (tgSy     - sy)    * kGen  }
        if !locks.contains("sx")    { sx    += (tgSx     - sx)    * kGen  }
        if !locks.contains("es")    { es    += (tgEs     - es)    * kGen  }

        // Animate color
        col = mixColor(col, colT, 1 - pow(0.002, dt))

        // Blink
        if now > nextBlink {
            if state != .sleeping && state != .dizzy {
                blink()
                if Double.random(in: 0...1) < 0.22 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) { [weak self] in self?.blink() }
                }
            }
            nextBlink = now + 2.2 + Double.random(in: 0...3.2)
        }

        // Clear expired eye override (restore permanent if set)
        if eyeOverride != nil && now > eyeOverrideUntil {
            eyeOverride = permanentEye
            if permanentEye != nil { eyeOverrideUntil = .greatestFiniteMagnitude }
        }

        // Ambient particles
        if now - lastAmbient > 1.3 {
            lastAmbient = now
            if cfg.zz { emit(.z, count: 1) }   // ZZZ works for mini too
            if !isMini && cfg.sweat && Double.random(in: 0...1) < 0.5 { emit(.sweat, count: 1) }
        }

        // Age particles
        for i in particles.indices { particles[i].age += dt }
        particles.removeAll { $0.age >= $0.life }

        // Mouth slot spring — ω₀ ≈ 25 rad/s (T=0.25s), ζ=0.6 (underdamped, slight clack)
        let slotOmega: CGFloat = 2 * .pi / 0.25
        let slotZeta: CGFloat = 0.6
        let slotAcc = slotOmega * slotOmega * (slotHTarget - slotH)
                    - 2 * slotZeta * slotOmega * slotHVel
        slotHVel += slotAcc * dtCG
        slotH = max(0, slotH + slotHVel * dtCG)

        lastTime = now
    }
}
