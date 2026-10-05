import AppKit

/// Mochi moves with the music (#117): runs NowPlayingMonitor only while the setting is on (no
/// observers, no work otherwise) and publishes the little the animation needs: whether something
/// plays, and a counter that goes up on each new song. The bob itself lives in BotEngine; the
/// full now-playing pill and card are #107.
@MainActor
final class MochiDanceController {
    static let shared = MochiDanceController()

    private var tracker = MochiDance.Tracker()
    private var started = false
    private var running = false

    func start() {
        guard !started else { return }
        started = true
        // Reduce Motion changes arrive as a workspace notification: no polling.
        AppState.shared.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppState.shared.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
        update()
    }

    /// Starts or stops listening to Music / Spotify to match the setting.
    func update() {
        let monitor = NowPlayingMonitor.shared
        if AppState.shared.mochiDance {
            guard !running else { return }
            running = true
            monitor.onChange = { MochiDanceController.shared.nowPlayingChanged() }
            monitor.start()
            nowPlayingChanged()
        } else {
            guard running else { return }
            running = false
            monitor.onChange = nil
            monitor.stop()
            tracker = MochiDance.Tracker()
            publish()
        }
    }

    private func nowPlayingChanged() {
        tracker.apply(NowPlayingMonitor.shared.active)
        publish()
    }

    private func publish() {
        let s = AppState.shared
        if s.musicPlaying != tracker.playing { s.musicPlaying = tracker.playing }
        if s.musicTrackChanges != tracker.changes { s.musicTrackChanges = tracker.changes }
    }
}
