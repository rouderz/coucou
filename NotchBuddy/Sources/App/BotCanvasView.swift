import AppKit
import SwiftUI

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    /// Drawn in the free-floating window (Settings → Display → Free): keeps animating while
    /// the island is hidden and looks at the pointer from where that window is.
    var freeBuddy: Bool = false
    /// Free placement, a character in charge of an integration (#151): shows that task's state.
    var buddyTaskID: String? = nil
    private var buddyKey: String { buddyTaskID ?? FreeBuddyController.mainKey }
    /// Free placement: emotes, clicks and drops go to the character they're about (the one
    /// clicked, whose island is open) — clicking Pip makes only Pip react.
    private var reacts: Bool { !freeBuddy || FreeBuddyController.reactingKey == buddyKey }

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()

    var body: some View {
        TimelineView(AlignedAnimationSchedule(interval: freeBuddy ? FrameRate.calm : FrameRate.mochi(for: state),
                                              paused: !freeBuddy && state.mode == .hidden)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dtRaw = min(0.05, now - engine.lastTime)
                let dt = dtRaw
                if freeBuddy {
                    let m = NSEvent.mouseLocation, c = FreeBuddyController.centers[buddyKey] ?? m
                    engine.lookX = tanh((m.x - c.x) / 260)
                    engine.lookY = tanh((m.y - c.y) / 200)
                    let shown = buddyTaskID.map { id in state.tasks.first { $0.id == id }?.state ?? .idle }
                        ?? state.mainBuddyState
                    if engine.state != shown { engine.setState(shown) }
                } else {
                    engine.lookX = lookX(state: state, size: size)
                    engine.lookY = lookY(state: state, size: size)
                }
                engine.particleOverhang = particleOverhang
                let shownTask = freeBuddy ? buddyTaskID : state.focusTask?.id
                engine.critter = state.critter(for: shownTask)
                engine.userTint = state.critterAssignments[shownTask ?? ""] != nil ? state.critterTint(for: shownTask) : nil
                // Widen slot when file is hovering over the mailbox (morph > 0.5)
                // Open mouth (hover=0.20R) when file dragged over box; close when not
                if engine.morph > 0.3 {
                    engine.slotHTarget = state.fileDragOver ? 0.20 : 0
                } else {
                    engine.slotHTarget = 0
                    if engine.morph < 0.05 { engine.slotH = 0; engine.slotHVel = 0 }
                }
                // Integration pills have a fixed brand color → use it as bodyColor.
                // Claude Code tasks use state-based gradient (working=blue, thinking=purple, etc.).
                // An integration with its own character (#151) keeps its colours; the others are
                // drawn flat in the pill colour.
                engine.bodyColor = (!freeBuddy && state.focusTask?.isIntegration == true
                                    && state.critterAssignments[state.focusTask!.id] == nil)
                    ? cgColorFromHex(state.focusTask!.color)
                    : nil
                // Bobs to the music (#117) while idle; the engine eases it in and out.
                engine.dancing = state.mochiDancing
                engine.update(dt: dt)
                engine.drawHandsBehind(context: context, size: size)
                engine.draw(context: context, size: size)
                engine.drawHandsAndExtras(context: context, size: size)
            }
        }
        .onChange(of: state.effectiveState) { _, newState in
            if !freeBuddy { engine.setState(newState) }
            applyFocusLook()
        }
        .onChange(of: state.focus.phase) { _, _ in applyFocusLook() }
        .onChange(of: state.focus.paused) { _, _ in applyFocusLook() }
        .onChange(of: state.musicTrackChanges) { _, _ in
            // New song (#117): headphones, only when Mochi is dancing and can be seen.
            if reacts && state.mochiDancing && state.mode != .hidden { engine.headphones() }
        }
        .onChange(of: state.view) { _, newView in
            // Morph up when upload view is active
            if state.mode == .expanded && newView == .upload {
                engine.anim("morph", keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
            } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                // Any other view (not mid-gulp): morph back
                engine.anim("morph", keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
            }
        }
        .onChange(of: state.mode) { _, newMode in
            // Hard-reset morph when island collapses
            if newMode != .expanded {
                engine.tweens.removeValue(forKey: "morph")
                engine.locks.remove("morph")
                engine.morph = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            if reacts, let emote = notif.object as? BotEmote {
                engine.triggerEmote(emote)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            if reacts { engine.slap() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            if reacts { engine.blink() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botSetTgEs)) { notif in
            if reacts, let v = notif.object as? CGFloat {
                engine.tgEs = v
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGulp)) { _ in
            if reacts { engine.gulp() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botMorphTo)) { notif in
            if reacts, let target = notif.object as? CGFloat {
                let dur: CGFloat = target > 0.5 ? 550 : 650
                engine.anim("morph", keys: [TweenKey(target: target, duration: dur, ease: Ease.inOut)])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            if reacts { engine.greet() }
        }
        .onAppear {
            engine.setState(state.effectiveState, force: true)
            applyFocusLook()
        }
    }

    /// Focus timer (#119): during a block Mochi looks concentrated (flat eyes) while nothing else
    /// is going on; Claude Code states and emotes still show over it.
    private func applyFocusLook() {
        let f = state.focus
        let on = f.phase == .focus && !f.paused && state.effectiveState == .idle
        let eye: EyeShape? = on ? .flat : nil
        guard engine.permanentEye != eye else { return }
        engine.permanentEye = eye
        if let eye {
            engine.eyeOverride = eye
            engine.eyeOverrideUntil = .greatestFiniteMagnitude
        } else if engine.eyeOverrideUntil == .greatestFiniteMagnitude {
            engine.eyeOverride = nil
            engine.eyeOverrideUntil = 0
        }
    }

    private func lookX(state: AppState, size: CGSize) -> CGFloat {
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let (botCx, _, _, _) = botPosition(mode: state.mode, view: state.view,
                                            islandW: islandW, islandH: islandH,
                                            uploadProgress: state.uploadProgress)
        // Island is centered on screen; bot is at botCx within island coords
        let botScreenX = state.islandScreenWidth / 2 - islandW / 2 + botCx
        return tanh((state.mousePosition.x - botScreenX) / 260)
    }

    private func lookY(state: AppState, size: CGSize) -> CGFloat {
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let (_, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                             islandW: islandW, islandH: actualH,
                                             uploadProgress: state.uploadProgress)
        // Island top = screen top → bot screen Y = botCy from island top
        return -tanh((state.mousePosition.y - botCy) / 200)
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    @StateObject private var engine: BotEngine
    @ObservedObject private var appState = AppState.shared

    init(task: AgentTask) {
        self.task = task
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    var body: some View {
        TimelineView(AlignedAnimationSchedule(interval: FrameRate.mini,
                                              paused: appState.mode == .hidden)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt = min(0.05, now - engine.lastTime)
                engine.critter = appState.critter(for: task.id)
                // Its own colour (#156) when its character has one, else the pill colour.
                engine.bodyColor = appState.critterTint(for: task.id) ?? cgColorFromHex(task.color)
                engine.update(dt: dt)
                engine.draw(context: context, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        .onAppear {
            engine.setState(task.state, force: true)
            if let emote = task.emote {
                engine.setPermanentEmote(emote)
            }
            // Direct eye override takes priority (e.g. .wide eyes for Research)
            if let eye = task.miniEye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
        }
    }
}

// MARK: - CGColor from hex string

func cgColorFromHex(_ hex: String) -> CGColor? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let val = UInt64(h, radix: 16) else { return nil }
    let r = CGFloat((val >> 16) & 0xFF) / 255
    let g = CGFloat((val >> 8)  & 0xFF) / 255
    let b = CGFloat( val        & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

extension CGColor {
    static func from(_ hex: String) -> CGColor {
        cgColorFromHex(hex) ?? CGColor(gray: 0.5, alpha: 1)
    }
}
