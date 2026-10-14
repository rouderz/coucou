import AppKit

// Which monitor the island lives on, and whether it should stay out of the way.
//
// "auto" = the screen with the notch, else the main screen (the old behaviour). Otherwise the
// choice is a CGDirectDisplayID as text; if that monitor is unplugged, auto takes over until it
// comes back.

extension Notification.Name {
    static let islandDisplayChanged = Notification.Name("notchBuddy.islandDisplayChanged")
}

enum IslandDisplay {
    static let auto = "auto"
    private static let choiceKey = "islandDisplay"
    private static let fullscreenKey = "islandHideInFullscreen"

    static var choice: String {
        get { UserDefaults.standard.string(forKey: choiceKey) ?? auto }
        set {
            UserDefaults.standard.set(newValue, forKey: choiceKey)
            NotificationCenter.default.post(name: .islandDisplayChanged, object: nil)
        }
    }

    /// Hide the island while a full-screen app covers its monitor (monitors without a notch only:
    /// on a notch the island sits in the notch and covers nothing).
    static var hideInFullscreen: Bool {
        get { UserDefaults.standard.object(forKey: fullscreenKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: fullscreenKey)
            NotificationCenter.default.post(name: .islandDisplayChanged, object: nil)
        }
    }

    static func id(of screen: NSScreen) -> String {
        let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return n.map { String($0.uint32Value) } ?? screen.localizedName
    }

    static func hasNotch(_ screen: NSScreen) -> Bool { screen.safeAreaInsets.top > 0 }

    /// The monitors for the picker, in the order macOS lists them (the first is the main one).
    static var screens: [(id: String, name: String)] {
        NSScreen.screens.map { s in
            let size = "\(Int(s.frame.width))×\(Int(s.frame.height))"
            return (id(of: s), "\(s.localizedName) · \(size)\(hasNotch(s) ? " · notch" : "")")
        }
    }

    static func resolve() -> NSScreen {
        if choice != auto, let s = NSScreen.screens.first(where: { id(of: $0) == choice }) { return s }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// True when another app's window covers the whole screen (a native full-screen Space).
    @MainActor
    static func fullscreenAppCovers(_ screen: NSScreen) -> Bool {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        // CG space: origin at the primary screen's top-left, y down.
        let sf = screen.frame
        let cg = CGRect(x: sf.minX, y: primary.frame.maxY - sf.maxY, width: sf.width, height: sf.height)
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
            let r = CGRect(x: x, y: y, width: w, height: h)
            if abs(r.minX - cg.minX) < 1, abs(r.minY - cg.minY) < 1, w >= cg.width - 1, h >= cg.height - 1 { return true }
        }
        return false
    }

    /// CG window coordinates flip around the primary screen, not the one the island is on.
    static var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
}
