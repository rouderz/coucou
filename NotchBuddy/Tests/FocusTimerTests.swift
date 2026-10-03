import XCTest
@testable import Coucou

/// Focus timer state machine (#119); mirrors windows/src/core/focus.test.ts.
final class FocusTimerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func fresh(_ config: FocusConfig = FocusConfig()) -> FocusState { FocusState(now: t0, config: config) }

    func testIdleDoesNothingAndRunsNoTimer() {
        let s = fresh()
        XCTAssertNil(s.nextWake(at: t0))
        for step in [s.tick(now: at(1), currentDnd: nil), s.skip(now: t0, currentDnd: nil), s.stop(now: t0, currentDnd: nil),
                     s.pause(now: t0, currentDnd: nil), s.resume(now: t0, currentDnd: nil)] {
            XCTAssertEqual(step.state.phase, .idle)
            XCTAssertNil(step.dnd)
            XCTAssertNil(step.event)
        }
    }

    func testBlockTurnsDndOnThenBreakThenIdle() {
        var step = fresh().start(now: t0, currentDnd: nil)
        XCTAssertEqual(step.state.phase, .focus)
        XCTAssertEqual(step.event, .focusStarted)
        XCTAssertEqual(step.dnd, .some(at(25)))
        XCTAssertEqual(step.state.nextWake(at: t0), 25 * 60)
        XCTAssertEqual(FocusState.format(step.state.remaining(at: at(1))), "24:00")
        XCTAssertEqual(step.state.progress(at: at(5)), 0.2, accuracy: 0.0001)

        XCTAssertEqual(step.state.tick(now: at(24), currentDnd: at(25)).state.phase, .focus)

        step = step.state.tick(now: at(25), currentDnd: at(25))
        XCTAssertEqual(step.event, .focusDone)
        XCTAssertEqual(step.state.phase, .shortBreak)
        XCTAssertEqual(step.state.blocksToday, 1)
        XCTAssertEqual(step.dnd, .some(nil))  // it was off before: off again
        XCTAssertEqual(step.state.nextWake(at: at(25)), 5 * 60)

        step = step.state.tick(now: at(30), currentDnd: nil)
        XCTAssertEqual(step.event, .breakDone)
        XCTAssertEqual(step.state.phase, .idle)
        XCTAssertNil(step.state.nextWake(at: at(30)))
    }

    func testPreviousDndComesBack() {
        // Already on for 2 more hours: covers the block, left alone.
        var step = fresh().start(now: t0, currentDnd: at(120))
        XCTAssertNil(step.dnd)
        XCTAssertNil(step.state.tick(now: at(25), currentDnd: at(120)).dnd)

        // On for 10 minutes only: extended, then off (the saved value is over).
        step = fresh().start(now: t0, currentDnd: at(10))
        XCTAssertEqual(step.dnd, .some(at(25)))
        XCTAssertEqual(step.state.tick(now: at(25), currentDnd: at(25)).dnd, .some(nil))

        // Skipped after 5 minutes: the saved value is still ahead, so it is restored.
        step = fresh().start(now: t0, currentDnd: at(20))
        XCTAssertEqual(step.dnd, .some(at(25)))
        XCTAssertEqual(step.state.skip(now: at(5), currentDnd: at(25)).dnd, .some(at(20)))
    }

    func testDndChangedByTheUserIsNotTouched() {
        let step = fresh().start(now: t0, currentDnd: nil)
        XCTAssertNil(step.state.tick(now: at(25), currentDnd: nil).dnd)
        XCTAssertNil(step.state.stop(now: at(1), currentDnd: at(180)).dnd)
        XCTAssertEqual(step.state.stop(now: at(1), currentDnd: at(25)).dnd, .some(nil))
    }

    func testLongBreakAfterNBlocks() {
        var s = fresh(FocusConfig(blocksBeforeLong: 3))
        var now = t0
        var seen: [FocusPhase] = []
        for _ in 0..<4 {
            let started = s.start(now: now, currentDnd: nil)
            now = now.addingTimeInterval(25 * 60)
            let ended = started.state.tick(now: now, currentDnd: now)
            seen.append(ended.state.phase)
            now = now.addingTimeInterval(ended.state.duration)
            s = ended.state.tick(now: now, currentDnd: nil).state
        }
        XCTAssertEqual(seen, [.shortBreak, .shortBreak, .longBreak, .shortBreak])
        XCTAssertEqual(s.blocksToday, 4)
        XCTAssertEqual(s.cycle, 1)
    }

    func testPauseFreesDndAndResumeTakesItAgain() {
        var step = fresh().start(now: t0, currentDnd: nil)
        let paused = step.state.pause(now: at(10), currentDnd: at(25))
        XCTAssertTrue(paused.state.paused)
        XCTAssertEqual(paused.dnd, .some(nil))
        XCTAssertNil(paused.state.nextWake(at: at(10)))  // no timer while paused
        XCTAssertEqual(paused.state.remaining(at: at(99)), 15 * 60)
        XCTAssertEqual(paused.state.tick(now: at(99), currentDnd: nil).state.phase, .focus)

        step = paused.state.resume(now: at(40), currentDnd: nil)
        XCTAssertFalse(step.state.paused)
        XCTAssertEqual(step.dnd, .some(at(55)))
        XCTAssertEqual(step.state.nextWake(at: at(40)), 15 * 60)
        XCTAssertNil(step.state.resume(now: at(41), currentDnd: nil).event)
    }

    func testPausingABreakTouchesNoDnd() {
        let b = fresh().start(now: t0, currentDnd: nil).state.tick(now: at(25), currentDnd: nil).state
        let p = b.pause(now: at(26), currentDnd: nil)
        XCTAssertNil(p.dnd)
        XCTAssertNil(p.state.resume(now: at(27), currentDnd: nil).dnd)
    }

    func testSkipAndStop() {
        let f = fresh().start(now: t0, currentDnd: nil).state
        let skipped = f.skip(now: at(5), currentDnd: at(25))
        XCTAssertEqual(skipped.state.phase, .shortBreak)
        XCTAssertEqual(skipped.state.blocksToday, 0)  // not counted
        XCTAssertEqual(skipped.dnd, .some(nil))
        XCTAssertEqual(skipped.state.skip(now: at(6), currentDnd: nil).state.phase, .idle)

        let stopped = f.stop(now: at(5), currentDnd: at(25))
        XCTAssertEqual(stopped.state.phase, .idle)
        XCTAssertEqual(stopped.event, .stopped)
        XCTAssertEqual(stopped.dnd, .some(nil))
        XCTAssertEqual(stopped.state.cycle, 0)
        XCTAssertEqual(stopped.state.start(now: at(6), currentDnd: nil).state.phase, .focus)
    }

    func testStartWhileRunningDoesNothingAndCustomMinutesApplyOnce() {
        let a = fresh().start(now: t0, currentDnd: nil, minutes: 50)
        XCTAssertEqual(a.dnd, .some(at(50)))
        XCTAssertEqual(a.state.config.focusMinutes, 25)
        let again = a.state.start(now: at(1), currentDnd: nil, minutes: 10)
        XCTAssertEqual(again.state, a.state)
        XCTAssertNil(again.dnd)
    }

    func testBlocksTodayResetOnANewDay() {
        var s = fresh()
        s = s.start(now: t0, currentDnd: nil).state.tick(now: at(25), currentDnd: nil).state
        XCTAssertEqual(s.blocksToday, 1)
        XCTAssertEqual(s.skip(now: at(24 * 60), currentDnd: nil).state.blocksToday, 0)
        XCTAssertEqual(FocusConfig(focusMinutes: 0, breakMinutes: -3).sanitized().focusMinutes, 1)
        XCTAssertEqual(FocusState.format(0), "00:00")
        XCTAssertEqual(FocusState.format(0.2), "00:01")
    }
}
