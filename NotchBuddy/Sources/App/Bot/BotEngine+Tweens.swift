import Foundation
import CoreGraphics
import SwiftUI

@MainActor
extension BotEngine {
    // MARK: - Tween helpers

    func anim(_ key: String, keys: [TweenKey], onComplete: (() -> Void)? = nil) {
        let current = getProperty(key)
        tweens[key] = Tween(property: key, keys: keys, keyIndex: 0,
                            from: current, startTime: CACurrentMediaTime() * 1000,
                            onComplete: onComplete)
        locks.insert(key)
    }

    func setTarget(key: String, value: CGFloat) {
        guard !locks.contains(key) else { return }
        switch key {
        case "tint":  tint  += (value - tint)  // immediate target, smoothed in update
        case "tilt":  tgTilt = value
        default: break
        }
    }

    func setProperty(_ key: String, value: CGFloat) {
        switch key {
        case "yaw":    yaw    = value
        case "pitch":  pitch  = value
        case "roll":   roll   = value
        case "tilt":   tilt   = value
        case "open":   open   = value
        case "sx":     sx     = value
        case "sy":     sy     = value
        case "oy":     oy     = value
        case "ox":     ox     = value
        case "tint":   tint   = value
        case "morph":  morph  = value
        case "hands":  hands  = value
        case "blush":  blush  = value
        case "es":     es     = value
        case "badgeS": badgeS = value
        default: break
        }
    }

    func getProperty(_ key: String) -> CGFloat {
        switch key {
        case "yaw":    return yaw
        case "pitch":  return pitch
        case "roll":   return roll
        case "tilt":   return tilt
        case "open":   return open
        case "sx":     return sx
        case "sy":     return sy
        case "oy":     return oy
        case "ox":     return ox
        case "tint":   return tint
        case "morph":  return morph
        case "hands":  return hands
        case "blush":  return blush
        case "es":     return es
        case "badgeS": return badgeS
        default:       return 0
        }
    }
}
