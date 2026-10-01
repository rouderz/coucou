import AppKit
import Carbon
import OSLog

let assistantLog = Logger(subsystem: "fr.louisraille.NotchBuddy", category: "assistant")

/// A system-wide keyboard shortcut registered with macOS (`RegisterEventHotKey`).
///
/// Unlike `NSEvent.addGlobalMonitorForEvents`, it needs no Accessibility permission
/// (so it keeps working after every ad-hoc-signed Debug build) and it consumes the
/// keystroke, so the shortcut never reaches the frontmost app.
@MainActor
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let action: @MainActor () -> Void

    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private static let signature: OSType = 0x434F_5543  // 'COUC'

    init(action: @escaping @MainActor () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action
        Self.installHandler()
        Self.registry[id] = self
    }

    /// Registers (or re-registers) the shortcut. `flags` are NSEvent.ModifierFlags raw values.
    @discardableResult
    func register(keyCode: UInt16, flags: UInt) -> Bool {
        unregister()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(flags), hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        assistantLog.info("hotkey register key=\(keyCode) flags=\(flags) status=\(status)")
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private static func carbonModifiers(_ flags: UInt) -> UInt32 {
        let f = NSEvent.ModifierFlags(rawValue: flags)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift)   { m |= UInt32(shiftKey) }
        if f.contains(.option)  { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            assistantLog.info("hotkey pressed id=\(id)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.registry[id]?.action() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Accessibility permission, needed to read the open file and the selection.
enum AccessibilityAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and opens Privacy & Security → Accessibility.
    @MainActor
    static func request() {
        // Literal value of kAXTrustedCheckOptionPrompt (the C global isn't concurrency-safe in Swift 6).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
