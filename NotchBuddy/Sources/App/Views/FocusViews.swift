import SwiftUI

// Focus timer (#119): the ring around Mochi, the ⏱ in the island's top bar, the controls on the
// Claude Code card, the end-of-block prompt and Settings → Focus. FocusTimer.swift runs the clock.
//
// Cost: nothing here owns a timer. The ring and the countdown only exist while a block or a break
// is on and the island is showing; the ring redraws every 2 s, the countdown is a system timer text.

enum FocusStyle {
    static func color(_ f: FocusTimerState) -> Color {
        if f.paused { return Color(hex: "#8E939C") }
        return f.phase == .focus ? Color(hex: "#A78BFA") : Color(hex: "#34D399")
    }

    static func phaseName(_ f: FocusTimerState) -> String {
        switch f.phase {
        case .idle: return L("Focus")
        case .focus: return f.paused ? L("Focus · paused") : L("Focus")
        case .shortBreak: return f.paused ? L("Break · paused") : L("Break")
        case .longBreak: return f.paused ? L("Long break · paused") : L("Long break")
        }
    }

    /// Lengths offered to start a block: the configured one, then 25 and 50.
    static func lengths(_ configured: Int) -> [Int] {
        var out = [configured]
        for m in [25, 50] where !out.contains(m) { out.append(m) }
        return out
    }
}

/// "24:59", counting down by itself while running; frozen while paused.
struct FocusTimeText: View {
    let focus: FocusTimerState

    var body: some View {
        if !focus.paused, let end = focus.endsAt {
            let now = Date.now
            Text(timerInterval: min(now, end)...end, countsDown: true, showsHours: false)
        } else {
            Text(FocusTimerState.format(focus.remaining(at: .now)))
        }
    }
}

// MARK: - Ring around Mochi

/// What's left of the block, as a thin bar under Mochi (it empties as time passes). It used to be a
/// ring around Mochi, but Mochi isn't round: the ring cut through its body.
struct FocusRing: View {
    @ObservedObject var state: AppState
    let diameter: CGFloat

    var body: some View {
        let f = state.focus
        if f.phase != .idle && state.mode != .hidden {
            TimelineView(AlignedAnimationSchedule(interval: 2, paused: f.paused)) { tl in
                let left = 1 - f.progress(at: tl.date)
                let width = diameter * 0.6
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(FocusStyle.color(f))
                        .frame(width: max(3, width * left))
                }
                .frame(width: width, height: 3)
                // Under Mochi: the frame is Mochi-sized and centred on it, the bar sits at its bottom.
                .frame(width: diameter, height: diameter * 0.74, alignment: .bottom)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Top bar

/// ⏱ in the island's top bar. Click: start a block, pause or resume. Right-click: lengths, skip, stop.
struct FocusHeaderButton: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        let f = state.focus
        let timer = FocusTimer.shared
        Button { timer.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: f.paused ? "pause.circle" : "timer")
                    .font(.system(size: 13))
                if f.phase != .idle {
                    FocusTimeText(focus: f)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .fixedSize()
                }
            }
            .foregroundColor(f.phase == .idle ? Color(hex: "#8E939C") : FocusStyle.color(f))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if f.phase == .idle {
                ForEach(FocusStyle.lengths(state.focusConfig.focusMinutes), id: \.self) { m in
                    Button(L("Focus \(m) min")) { timer.start(minutes: m) }
                }
            } else {
                Button(f.paused ? L("Resume") : L("Pause")) { timer.toggle() }
                Button(f.phase == .focus ? L("Skip to the break") : L("Skip the break")) { timer.skip() }
                Button(L("Stop")) { timer.stop() }
            }
            Divider()
            Text(L("Blocks today: \(f.blocksDone(at: .now))"))
        }
        .help(f.phase == .idle
              ? L("Focus: start a \(state.focusConfig.focusMinutes)-min block (right-click for more)")
              : L("Focus: click to pause or resume (right-click for more)"))
    }
}

// MARK: - Claude Code card

/// Small round icon button used by the card controls.
private struct FocusIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The running block on the Claude Code card: phase, time left, pause / skip / stop, blocks today.
struct FocusCardPanel: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        let f = state.focus
        let timer = FocusTimer.shared
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(FocusStyle.color(f)).frame(width: 5, height: 5)
                Text(FocusStyle.phaseName(f))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                if f.phase == .focus, let issue = state.focusIssue {
                    Text(issue)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(L("\(f.blocksDone(at: .now)) today"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize()
            }
            HStack(spacing: 6) {
                FocusTimeText(focus: f)
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .fixedSize()
                Spacer(minLength: 4)
                FocusIconButton(icon: f.paused ? "play.fill" : "pause.fill",
                                help: f.paused ? L("Resume") : L("Pause")) { timer.toggle() }
                FocusIconButton(icon: "forward.end.fill",
                                help: f.phase == .focus ? L("Skip to the break") : L("Skip the break")) { timer.skip() }
                FocusIconButton(icon: "stop.fill", help: L("Stop")) { timer.stop() }
            }
        }
    }
}

/// "⏱ Focus" in the card's action row while no block is running.
struct FocusStartButton: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        let done = state.focus.blocksDone(at: .now)
        Button { FocusTimer.shared.start() } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer").font(.system(size: 10, weight: .medium))
                Text(done > 0 ? L("Focus · \(done)") : L("Focus"))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color(hex: "#A78BFA").opacity(0.85))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L("Start a \(state.focusConfig.focusMinutes)-min focus block with Do not disturb · \(done) done today"))
    }
}

// MARK: - End of block / break prompt

/// Buttons under the note when it is the focus prompt ("Block done! Break, 5 min?").
struct FocusNoteButtons: View {
    @ObservedObject var state: AppState
    let note: FocusNote

    private func done() {
        state.focusNote = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .overview }
    }

    var body: some View {
        HStack(spacing: 8) {
            switch note.kind {
            case .blockDone:
                PrimaryButton("Take the break") { done() }
                SecondaryButton("Keep working") { FocusTimer.shared.keepWorking(); done() }
            case .breakDone:
                PrimaryButton("Start focus") { FocusTimer.shared.start(); done() }
                SecondaryButton("Later") { done() }
            }
        }
    }
}

// MARK: - Settings → Focus

struct FocusSettingsSection: View {
    @ObservedObject var state: AppState

    private func minutes(_ key: WritableKeyPath<FocusConfig, Int>) -> Binding<Int> {
        Binding(get: { state.focusConfig[keyPath: key] },
                set: { var c = state.focusConfig; c[keyPath: key] = $0; state.focusConfig = c.sanitized() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: minutes(\.focusMinutes), in: 5...180, step: 5) {
                Text(L("Focus block: \(state.focusConfig.focusMinutes) min"))
            }
            Stepper(value: minutes(\.breakMinutes), in: 1...60) {
                Text(L("Break: \(state.focusConfig.breakMinutes) min"))
            }
            Stepper(value: minutes(\.longBreakMinutes), in: 1...90) {
                Text(L("Long break: \(state.focusConfig.longBreakMinutes) min"))
            }
            Stepper(value: minutes(\.blocksBeforeLong), in: 1...12) {
                Text(L("Long break after \(state.focusConfig.blocksBeforeLong) blocks"))
            }
            Toggle("Turn off Hey Mochi during focus blocks", isOn: $state.focusMutesWakeWord)
            Toggle("Shortcut ⌃⌥F: start, pause or resume a block", isOn: $state.focusHotkeyEnabled)
            Text("Do not disturb is on during each block and goes back to how it was at the end; approvals still reach the island, quietly. Start a block from the ⏱ in the island, the Claude Code card, the shortcut, or the chat: “focus 50 min on SHO-475”.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
    }
}
