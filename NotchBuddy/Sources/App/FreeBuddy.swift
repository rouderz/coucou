import AppKit
import SwiftUI

// Free placement (Settings → Display → Where it lives).
//
// In the notch (default): the island lives at the top of the screen as before.
// Free: the character floats in its own small window that you drag anywhere. A click opens the
// island right next to it, a second click (or moving away) folds it again; right-click offers to
// go back to the notch. The island itself stays invisible while it isn't open, so nothing peeks
// from the top of the screen in this mode. The position is remembered across launches.

extension Notification.Name {
    static let islandPlacementChanged = Notification.Name("notchBuddy.islandPlacementChanged")
}

enum IslandPlacement: String, CaseIterable, Sendable {
    case notch, free

    private static let key = "islandPlacement"
    private static let originKey = "freeBuddyOrigin"

    static var current: IslandPlacement {
        get { IslandPlacement(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .notch }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .islandPlacementChanged, object: nil)
        }
    }

    static var isFree: Bool { current == .free }

    /// Bottom-left corner of the floating window, in global screen coordinates.
    static var savedOrigin: NSPoint? {
        get {
            guard let a = UserDefaults.standard.array(forKey: originKey) as? [Double], a.count == 2 else { return nil }
            return NSPoint(x: a[0], y: a[1])
        }
        set {
            if let p = newValue { UserDefaults.standard.set([Double(p.x), Double(p.y)], forKey: originKey) }
            else { UserDefaults.standard.removeObject(forKey: originKey) }
        }
    }
}

// MARK: - Controller

@MainActor
final class FreeBuddyController {
    static let size = NSSize(width: 104, height: 112)

    /// Centre of the floating character on screen (global coords, y up): where it looks from.
    static private(set) var center: NSPoint = .zero

    private var panel: NSPanel?
    private let menuTarget = FreeBuddyMenu()

    /// Click (no drag) on the character.
    var onClick: (() -> Void)?

    var frame: NSRect? { panel?.frame }
    var isShown: Bool { panel != nil }

    /// Shows or removes the window to match the setting. Removing it frees the canvas (0 % CPU).
    func sync() {
        if IslandPlacement.isFree { show() } else { hide() }
    }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let origin = clamped(IslandPlacement.savedOrigin ?? defaultOrigin())
        panel.setFrameOrigin(origin)
        Self.center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Back to the default spot (bottom-right of the main screen).
    func resetPosition() {
        IslandPlacement.savedOrigin = nil
        if panel != nil { show() }
    }

    /// Screens can be unplugged or rearranged: keep the window fully on the screen it is over.
    func revalidate() {
        guard let panel else { return }
        let o = clamped(panel.frame.origin)
        if o != panel.frame.origin { panel.setFrameOrigin(o) }
        Self.center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    private func defaultOrigin() -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - Self.size.width - 40, y: vf.minY + 60)
    }

    private func clamped(_ p: NSPoint) -> NSPoint {
        let s = Self.size
        let mid = NSPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        return NSPoint(x: min(max(p.x, vf.minX), vf.maxX - s.width),
                       y: min(max(p.y, vf.minY), vf.maxY - s.height))
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        // Above normal windows, below the island (mainMenu + 3) so the open island covers it.
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false            // the drag view moves it, so a click stays a click
        p.isReleasedWhenClosed = false

        let drag = FreeBuddyDragView(frame: NSRect(origin: .zero, size: Self.size))
        drag.onClick = { [weak self] in self?.onClick?() }
        drag.onMoving = { frame in Self.center = NSPoint(x: frame.midX, y: frame.midY) }
        drag.onDropped = { [weak self] in
            guard let self, let panel = self.panel else { return }
            let o = self.clamped(panel.frame.origin)
            panel.setFrameOrigin(o)
            Self.center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            IslandPlacement.savedOrigin = o
        }
        drag.menu = menuTarget.makeMenu()

        let host = NSHostingView(rootView: FreeBuddyView().environmentObject(AppState.shared))
        host.frame = drag.bounds
        host.autoresizingMask = [.width, .height]
        drag.addSubview(host)
        p.contentView = drag
        return p
    }
}

// MARK: - The character

struct FreeBuddyView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        BotCanvasView(state: state, freeBuddy: true)
            .frame(width: FreeBuddyController.size.width, height: FreeBuddyController.size.height)
            .help(Text("Click to open, drag to move, right-click for options"))
    }
}

// MARK: - Drag / click handling

/// Takes every mouse event over the character (the SwiftUI view inside never sees them):
/// a press that moves more than a few points is a drag, otherwise it is a click.
final class FreeBuddyDragView: NSView {
    var onClick: (() -> Void)?
    var onMoving: ((NSRect) -> Void)?
    var onDropped: (() -> Void)?

    private var startMouse: NSPoint?
    private var startOrigin: NSPoint = .zero
    private var dragging = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse, let window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        if !dragging && hypot(dx, dy) < 4 { return }
        if !dragging { NSCursor.closedHand.push() }
        dragging = true
        window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        onMoving?(window.frame)
    }

    override func mouseUp(with event: NSEvent) {
        defer { startMouse = nil; dragging = false }
        if dragging {
            NSCursor.pop()
            onDropped?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

/// Right-click menu on the character.
@MainActor
final class FreeBuddyMenu: NSObject {
    func makeMenu() -> NSMenu {
        let m = NSMenu()
        let back = NSMenuItem(title: L("Back to the notch"), action: #selector(backToNotch), keyEquivalent: "")
        back.target = self
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        m.addItem(back)
        m.addItem(.separator())
        m.addItem(settings)
        return m
    }

    @objc private func backToNotch() { IslandPlacement.current = .notch }
    @objc private func openSettings() { NotificationCenter.default.post(name: .openFullSettings, object: nil) }
}
