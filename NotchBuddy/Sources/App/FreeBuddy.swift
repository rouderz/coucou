import AppKit
import SwiftUI

// Free placement (Settings → Display → Where it lives).
//
// In the notch (default): the island lives at the top of the screen as before.
// Free: the character floats in its own small window that you drag anywhere. A click opens the
// island right next to it, a second click (or moving away) folds it again; right-click offers to
// go back to the notch. The island itself stays invisible while it isn't open, so nothing peeks
// from the top of the screen in this mode. The position is remembered across launches.

extension NSUserInterfaceItemIdentifier {
    /// The Settings window: in free placement the main character sits on its title bar (#154).
    static let coucouSettings = NSUserInterfaceItemIdentifier("coucou.settings")
}

extension Notification.Name {
    static let islandPlacementChanged = Notification.Name("notchBuddy.islandPlacementChanged")
    static let freeBuddyReset = Notification.Name("notchBuddy.freeBuddyReset")
}

enum IslandPlacement: String, CaseIterable, Sendable {
    case notch, free

    private static let key = "islandPlacement"
    private static let originKey = "freeBuddyOrigin"          // the main character (older builds)
    private static let originsKey = "freeBuddyOrigins"        // one per character: [key: [x, y]]

    static var current: IslandPlacement {
        get { IslandPlacement(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .notch }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .islandPlacementChanged, object: nil)
        }
    }

    static var isFree: Bool { current == .free }

    private static let groundedKey = "groundedCharacters"
    /// Characters kept off the desktop one by one (Settings → Characters): they stay in the rail.
    static func floats(_ taskID: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: groundedKey) ?? []).contains(taskID)
    }
    static func setFloats(_ taskID: String, _ on: Bool) {
        var grounded = Set(UserDefaults.standard.stringArray(forKey: groundedKey) ?? [])
        if on { grounded.remove(taskID) } else { grounded.insert(taskID) }
        UserDefaults.standard.set(Array(grounded).sorted(), forKey: groundedKey)
        NotificationCenter.default.post(name: .islandPlacementChanged, object: nil)
    }

    private static let floatAllKey = "floatAllCharacters"
    /// Every character floats on its own (on by default), or just the main one — the others are
    /// still in the island's character rail.
    static var floatAll: Bool {
        get { UserDefaults.standard.object(forKey: floatAllKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: floatAllKey)
            NotificationCenter.default.post(name: .islandPlacementChanged, object: nil)
        }
    }

    /// Bottom-left corner of a floating character, in global screen coordinates.
    /// `key` is "main" (Claude Code) or the id of the integration it handles.
    static func savedOrigin(_ key: String) -> NSPoint? {
        let all = UserDefaults.standard.dictionary(forKey: originsKey) as? [String: [Double]] ?? [:]
        if let a = all[key], a.count == 2 { return NSPoint(x: a[0], y: a[1]) }
        if key == FreeBuddyController.mainKey,
           let a = UserDefaults.standard.array(forKey: originKey) as? [Double], a.count == 2 {
            return NSPoint(x: a[0], y: a[1])
        }
        return nil
    }

    static func setSavedOrigin(_ key: String, _ p: NSPoint?) {
        var all = UserDefaults.standard.dictionary(forKey: originsKey) as? [String: [Double]] ?? [:]
        all[key] = p.map { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(all, forKey: originsKey)
        if key == FreeBuddyController.mainKey && p == nil { UserDefaults.standard.removeObject(forKey: originKey) }
    }

    /// Every character back to its default spot.
    static func resetOrigins() {
        UserDefaults.standard.removeObject(forKey: originsKey)
        UserDefaults.standard.removeObject(forKey: originKey)
    }
}

/// Cards leave room on their left for the character; in free placement it sits on top of the
/// island instead, so the room goes back to the text.
@MainActor func botInset(_ notch: CGFloat) -> CGFloat {
    let state = AppState.shared
    // The character rail (CharacterRail.swift) sits beside the cards, not inside them.
    if state.railShown { return notch - 92 }
    return state.freePlacement ? notch - 88 : notch
}

// MARK: - Controller

/// The floating characters: the main one (Claude Code) and one per integration that has its
/// own character (Settings → General → Character, "Who handles what").
@MainActor
final class FreeBuddyController {
    static let size = NSSize(width: 104, height: 112)
    nonisolated static let mainKey = "main"

    /// How far above the window's bottom edge the character's feet are: the island's top edge
    /// goes there, so it looks like the character sits on it.
    static let seat: CGFloat = 30

    /// Centre of each floating character on screen (global coords, y up): where it looks from.
    static private(set) var centers: [String: NSPoint] = [:]

    private var panels: [String: NSPanel] = [:]
    private var order: [String] = []
    private let menuTarget = FreeBuddyMenu()

    /// Click (no drag) on a character: its key.
    var onClick: ((String) -> Void)?
    /// A character was dropped somewhere new by the user (the open island follows it).
    var onMovedByUser: ((String) -> Void)?

    /// The character the open island belongs to (the last one clicked or alerted).
    var activeKey: String = FreeBuddyController.mainKey {
        didSet { Self.reactingKey = activeKey }
    }
    /// Whether this character floats on its own right now.
    func floats(_ key: String) -> Bool { panels[key] != nil }

    /// Only this character reacts to clicks, hovers, emotes and drops; the others carry on
    /// with their own task's state.
    static private(set) var reactingKey: String = FreeBuddyController.mainKey

    /// Where a window was before it hopped onto the open island, to go back when it folds.
    private var perchedFrom: (key: String, origin: NSPoint)?

    var isShown: Bool { !panels.isEmpty }

    /// Where the user left a character, even while it sits on the open island.
    func homeFrame(_ key: String) -> NSRect? {
        guard let panel = panels[key] ?? panels[Self.mainKey] else { return nil }
        if let p = perchedFrom, p.key == key { return NSRect(origin: p.origin, size: panel.frame.size) }
        return panel.frame
    }

    /// The island opened: the active character hops down (or up) so its feet sit on the
    /// island's top edge, in front of it.
    func perch(bottomY: CGFloat) {
        let key = panels[activeKey] != nil ? activeKey : Self.mainKey
        guard let panel = panels[key] else { return }
        if let p = perchedFrom, p.key != key { unperch() }
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
        guard abs(panel.frame.minY - bottomY) > 0.5 else { return }
        if perchedFrom == nil { perchedFrom = (key, panel.frame.origin) }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: bottomY))
        Self.centers[key] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    /// The Settings window is open (#154): the main character sits on its title bar, near the
    /// right end, and moves with it.
    func sit(onWindow frame: NSRect) {
        guard let panel = panels[Self.mainKey] else { return }
        if let p = perchedFrom, p.key != Self.mainKey { return }   // busy on the open island
        if perchedFrom == nil { perchedFrom = (Self.mainKey, panel.frame.origin) }
        let x = min(frame.maxX - Self.size.width - 90, max(frame.minX + 8, frame.midX))
        panel.setFrameOrigin(NSPoint(x: x, y: frame.maxY - Self.seat))
        panel.orderFrontRegardless()
        Self.centers[Self.mainKey] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    /// The island folded: everyone back to their own spot, behind other floating panels again.
    func unperch() {
        for panel in panels.values { panel.level = .floating }
        if let p = perchedFrom, let panel = panels[p.key] {
            panel.setFrameOrigin(p.origin)
            Self.centers[p.key] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        }
        perchedFrom = nil
    }

    /// Shows the characters for these keys (main first) and removes the others, or all of them
    /// outside free placement. A removed window frees its canvas (0 % CPU).
    func sync(keys: [String]) {
        let wanted = IslandPlacement.isFree ? keys : []
        for key in panels.keys where !wanted.contains(key) { remove(key) }
        order = wanted
        for (i, key) in wanted.enumerated() where panels[key] == nil { show(key, index: i) }
        if panels[activeKey] == nil { activeKey = Self.mainKey }
    }

    private func show(_ key: String, index: Int) {
        let panel = makePanel(key)
        panels[key] = panel
        let origin = clamped(IslandPlacement.savedOrigin(key) ?? defaultOrigin(index))
        panel.setFrameOrigin(origin)
        Self.centers[key] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.orderFrontRegardless()
    }

    private func remove(_ key: String) {
        if perchedFrom?.key == key { perchedFrom = nil }
        panels[key]?.orderOut(nil)
        panels[key]?.contentView = nil
        panels[key] = nil
        Self.centers[key] = nil
    }

    /// Everyone back to the default spots (a row along the bottom-right of the main screen).
    func resetPositions() {
        IslandPlacement.resetOrigins()
        perchedFrom = nil
        for (i, key) in order.enumerated() {
            guard let panel = panels[key] else { continue }
            panel.setFrameOrigin(clamped(defaultOrigin(i)))
            Self.centers[key] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        }
    }

    /// Screens can be unplugged or rearranged: keep every window fully on the screen it is over.
    func revalidate() {
        for (key, panel) in panels {
            let o = clamped(panel.frame.origin)
            if o != panel.frame.origin { panel.setFrameOrigin(o) }
            Self.centers[key] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        }
    }

    private func defaultOrigin(_ index: Int) -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - Self.size.width - 40 - CGFloat(index) * (Self.size.width + 8), y: vf.minY + 60)
    }

    private func clamped(_ p: NSPoint) -> NSPoint {
        let s = Self.size
        let mid = NSPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        return NSPoint(x: min(max(p.x, vf.minX), vf.maxX - s.width),
                       y: min(max(p.y, vf.minY), vf.maxY - s.height))
    }

    private func makePanel(_ key: String) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        // Above normal windows, below the island (mainMenu + 3); perch() lifts the active one.
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false            // the drag view moves it, so a click stays a click
        p.isReleasedWhenClosed = false

        let drag = FreeBuddyDragView(frame: NSRect(origin: .zero, size: Self.size))
        drag.onClick = { [weak self] in self?.onClick?(key) }
        drag.onMoving = { frame in Self.centers[key] = NSPoint(x: frame.midX, y: frame.midY) }
        drag.onDropped = { [weak self] in
            guard let self, let panel = self.panels[key] else { return }
            let o = self.clamped(panel.frame.origin)
            panel.setFrameOrigin(o)
            Self.centers[key] = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            IslandPlacement.setSavedOrigin(key, o)
            if self.perchedFrom?.key == key { self.perchedFrom = nil }
            self.onMovedByUser?(key)
        }
        drag.menu = menuTarget.makeMenu()

        let task: String? = key == Self.mainKey ? nil : key
        let host = NSHostingView(rootView: FreeBuddyView(taskID: task).environmentObject(AppState.shared))
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
    /// The integration this character handles; nil for the main one (Claude Code).
    let taskID: String?

    var body: some View {
        BotCanvasView(state: state, freeBuddy: true, buddyTaskID: taskID)
            .frame(width: FreeBuddyController.size.width, height: FreeBuddyController.size.height)
            .help(Text(verbatim: helpText))
    }

    private var helpText: String {
        let name = state.critter(for: taskID).displayName
        let job = taskID.flatMap { id in state.tasks.first { $0.id == id }?.name } ?? "Claude Code"
        return "\(name) · \(job)"
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
        let all = NSMenuItem(title: L("Show every character"), action: #selector(toggleAll), keyEquivalent: "")
        all.target = self
        all.state = IslandPlacement.floatAll ? .on : .off
        m.addItem(back)
        m.addItem(all)
        m.addItem(.separator())
        m.addItem(settings)
        return m
    }

    @objc private func toggleAll() { IslandPlacement.floatAll.toggle() }

    @objc private func backToNotch() { IslandPlacement.current = .notch }
    @objc private func openSettings() { NotificationCenter.default.post(name: .openFullSettings, object: nil) }
}
