import XCTest
@testable import Coucou

/// CI pill logic (#115). Same cases as windows/src/core/ci.test.ts.
final class CIStatusTests: XCTestCase {
    private var nextID = 0
    private func run(_ name: String, _ status: String, _ conclusion: String? = nil, start: Date? = nil) -> CheckRun {
        nextID += 1
        return CheckRun(id: nextID, name: name, status: status, conclusion: conclusion, startedAt: start)
    }
    private func done(_ name: String, _ conclusion: String) -> CheckRun { run(name, "completed", conclusion) }
    private func pr(_ key: String, _ sha: String, _ runs: CheckRun...) -> PRCI {
        PRCI(key: key, sha: sha, summary: CICore.summarize(runs))
    }

    func testCheckStateMapping() {
        XCTAssertEqual(run("a", "queued").state, .running)
        XCTAssertEqual(run("a", "in_progress").state, .running)
        XCTAssertEqual(run("a", "waiting").state, .running)
        XCTAssertEqual(done("a", "success").state, .passed)
        for c in ["failure", "timed_out", "startup_failure"] { XCTAssertEqual(done("a", c).state, .failed) }
        XCTAssertEqual(done("a", "cancelled").state, .cancelled)
        XCTAssertEqual(done("a", "skipped").state, .skipped)
        for c in ["neutral", "stale", "action_required"] { XCTAssertEqual(done("a", c).state, .neutral) }
        XCTAssertEqual(run("a", "completed", nil).state, .neutral)
    }

    func testSummarizePriority() {
        func state(_ runs: CheckRun...) -> PRCIState { CICore.summarize(runs).state }
        XCTAssertEqual(state(done("a", "success"), done("b", "success")), .passed)
        XCTAssertEqual(state(done("a", "success"), run("b", "in_progress")), .running)
        let red = CICore.summarize([done("a", "failure"), run("b", "in_progress"), done("c", "success")])
        XCTAssertEqual(red.state, .failed, "red as soon as one fails")
        XCTAssertEqual([red.running, red.passed, red.failed, red.total], [1, 1, 1, 3])
        XCTAssertEqual(state(done("a", "success"), done("b", "skipped"), done("c", "neutral")), .passed)
        XCTAssertEqual(state(done("a", "skipped"), done("b", "neutral")), .neutral)
        XCTAssertEqual(state(done("a", "cancelled"), done("b", "skipped")), .cancelled)
        XCTAssertEqual(state(done("a", "cancelled"), done("b", "success")), .passed)
        XCTAssertEqual(CICore.summarize([]).state, .neutral)
        XCTAssertEqual(CICore.summarize([]).total, 0)
    }

    func testRerunKeepsNewestRun() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let old = run("build", "completed", "failure", start: t)
        let again = run("build", "in_progress", start: t.addingTimeInterval(300))
        XCTAssertEqual(CICore.latestRuns([again, old]).count, 1)
        XCTAssertEqual(CICore.summarize([old, again]).state, .running)
        let fixed = run("build", "completed", "success", start: t.addingTimeInterval(300))
        XCTAssertEqual(CICore.summarize([fixed, old]).state, .passed)
    }

    func testParseAndDuration() throws {
        let r = try XCTUnwrap(CheckRun.parse([
            "id": 7, "name": "build", "status": "completed", "conclusion": "success",
            "started_at": "2026-10-03T10:00:00Z", "completed_at": "2026-10-03T10:01:12Z",
            "html_url": "https://github.com/o/r/actions/runs/123/job/456",
        ]))
        XCTAssertEqual(r.durationSeconds(), 72)
        XCTAssertEqual(r.state, .passed)
        XCTAssertNil(CheckRun.parse(["name": "x", "status": "queued"]), "no id → skipped")
        let live = CheckRun(id: 1, name: "a", status: "in_progress", conclusion: nil,
                            startedAt: CICore.date("2026-10-03T10:00:00Z"))
        XCTAssertEqual(live.durationSeconds(now: CICore.date("2026-10-03T10:00:30Z")!), 30)
        XCTAssertNil(CheckRun(id: 2, name: "b", status: "queued").durationSeconds())
        let job = try XCTUnwrap(CICore.parseJobURL(r.htmlURL))
        XCTAssertEqual(job.runId, 123); XCTAssertEqual(job.jobId, 456)
        XCTAssertNil(CICore.parseJobURL("https://github.com/o/r/runs/789"))
        XCTAssertEqual(CICore.rerunFailedPath("o", "r", runId: 123), "repos/o/r/actions/runs/123/rerun-failed-jobs")
    }

    func testPillCountsRedAndBriefGreen() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        let running = { (k: String, sha: String) in self.pr(k, sha, self.run("a", "in_progress")) }
        let passed = { (k: String, sha: String) in self.pr(k, sha, self.done("a", "success")) }
        let failed = { (k: String, sha: String) in self.pr(k, sha, self.done("a", "failure")) }

        var r = CICore.nextPill(PillMemory(), [running("1", "s1"), running("2", "s2"), passed("3", "s3")], now: t0)
        XCTAssertEqual(r.pill, PillState(color: .running, count: 2))
        XCTAssertTrue(r.events.isEmpty)

        r = CICore.nextPill(r.memory, [passed("1", "s1"), running("2", "s2"), passed("3", "s3")], now: at(30))
        XCTAssertEqual(r.pill, PillState(color: .running, count: 1))
        XCTAssertEqual(r.events, [CIEvent(kind: .passed, key: "1", sha: "s1")])

        r = CICore.nextPill(r.memory, [passed("1", "s1"), failed("2", "s2"), passed("3", "s3")], now: at(60))
        XCTAssertEqual(r.pill, PillState(color: .failed, count: 1))
        XCTAssertEqual(r.events, [CIEvent(kind: .failed, key: "2", sha: "s2")])
        r = CICore.nextPill(r.memory, [passed("1", "s1"), failed("2", "s2"), passed("3", "s3")], now: at(90))
        XCTAssertEqual(r.pill, PillState(color: .failed, count: 1))
        XCTAssertTrue(r.events.isEmpty, "no second event for the same red commit")

        r = CICore.nextPill(r.memory, [running("2", "s2b")], now: at(120))
        XCTAssertEqual(r.pill.color, .running)
        let tp = at(150)
        r = CICore.nextPill(r.memory, [passed("2", "s2b")], now: tp)
        XCTAssertEqual(r.pill, PillState(color: .passed, count: 0))
        XCTAssertEqual(r.events.map(\.kind), [.passed])
        r = CICore.nextPill(r.memory, [passed("2", "s2b")], now: tp.addingTimeInterval(CICore.greenSeconds - 1))
        XCTAssertEqual(r.pill.color, .passed)
        r = CICore.nextPill(r.memory, [passed("2", "s2b")], now: tp.addingTimeInterval(CICore.greenSeconds))
        XCTAssertEqual(r.pill.color, .idle)
    }

    func testFirstPollQuietAndForgetsClosedPRs() {
        let failed = { (sha: String) in self.pr("1", sha, self.done("a", "failure")) }
        let now = Date(timeIntervalSince1970: 0)
        var r = CICore.nextPill(PillMemory(), [failed("s1")], now: now)
        XCTAssertEqual(r.pill.color, .failed)
        XCTAssertTrue(r.events.isEmpty, "already red at launch: no event")
        r = CICore.nextPill(r.memory, [failed("s2")], now: now)
        XCTAssertEqual(r.events.map(\.kind), [.failed], "new commit, red again")
        r = CICore.nextPill(r.memory, [], now: now)
        XCTAssertEqual(r.pill, PillState(color: .idle, count: 0))
        XCTAssertTrue(r.memory.states.isEmpty)
    }

    func testPollInterval() {
        XCTAssertEqual(CICore.pollInterval(anyRunning: true, hidden: false), 30)
        XCTAssertEqual(CICore.pollInterval(anyRunning: false, hidden: false), 300)
        XCTAssertEqual(CICore.pollInterval(anyRunning: true, hidden: true), 120)
        XCTAssertEqual(CICore.pollInterval(anyRunning: false, hidden: true), 1200)
        XCTAssertEqual(CICore.pollInterval(anyRunning: true, hidden: false, failures: 2), 120)
        XCTAssertEqual(CICore.pollInterval(anyRunning: false, hidden: true, failures: 9), 1800)
        XCTAssertEqual(CICore.pollInterval(anyRunning: true, hidden: false, failures: -3), 30)
    }

    func testTrimLogTail() {
        let log = [
            "2026-10-03T10:00:00.1234567Z ##[group]Run npm test",
            "2026-10-03T10:00:01.0000000Z \u{1B}[31mFAIL\u{1B}[0m src/a.test.ts",
            "2026-10-03T10:00:02Z   expected 1, got 2",
            "",
        ].joined(separator: "\r\n")
        XCTAssertEqual(CICore.trimLogTail(log), "##[group]Run npm test\nFAIL src/a.test.ts\n  expected 1, got 2")

        let many = (0..<500).map { "line \($0)" }.joined(separator: "\n")
        let out = CICore.trimLogTail(many, maxLines: 50).components(separatedBy: "\n")
        XCTAssertEqual(out.first, "… (log cut, last lines only)")
        XCTAssertEqual(out.count, 51)
        XCTAssertEqual(out.last, "line 499")
        XCTAssertEqual(out[1], "line 450")

        XCTAssertEqual(CICore.trimLogTail(String(repeating: "y", count: 50), maxLines: 10, maxChars: 20),
                       String(repeating: "y", count: 20), "one huge line: its last chars")
        XCTAssertEqual(CICore.trimLogTail(""), "")
    }

    func testParseCheckRuns() {
        let json: [String: Any] = ["total_count": 3, "check_runs": [
            ["id": 7, "name": "build", "status": "completed", "conclusion": "failure",
             "started_at": "2026-10-01T10:00:00Z", "completed_at": "2026-10-01T10:02:05Z",
             "html_url": "https://github.com/o/r/actions/runs/11/job/22"],
            ["id": 8, "name": "lint", "status": "in_progress", "conclusion": NSNull()],
            ["name": "no id", "status": "queued"],
        ] as [[String: Any]]]
        let runs = CICore.parseCheckRuns(json)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].name, "build")
        XCTAssertEqual(runs[0].state, .failed)
        XCTAssertEqual(runs[0].durationSeconds(), 125)
        XCTAssertEqual(runs[0].htmlURL, "https://github.com/o/r/actions/runs/11/job/22")
        XCTAssertNil(runs[1].conclusion)
        XCTAssertNil(runs[1].startedAt)
        XCTAssertTrue(CICore.parseCheckRuns(nil).isEmpty)
        XCTAssertTrue(CICore.parseCheckRuns(["check_runs": "x"]).isEmpty)
    }

    func testCardRunsOrder() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let order = CICore.cardRuns([
            done("b-pass", "success"), run("a-run", "queued"), done("z-fail", "failure"), done("a-fail", "timed_out"),
            done("skip", "skipped"), run("dup", "completed", "failure", start: early),
            run("dup", "completed", "success", start: late),
        ]).map(\.name)
        XCTAssertEqual(order, ["a-fail", "z-fail", "a-run", "b-pass", "dup", "skip"])
    }

    func testFormatDurationAndPaths() {
        XCTAssertEqual(CICore.formatDuration(nil), "")
        XCTAssertEqual(CICore.formatDuration(45), "45s")
        XCTAssertEqual(CICore.formatDuration(187), "3m 07s")
        XCTAssertEqual(CICore.formatDuration(3720), "1h 02m")
        XCTAssertTrue(CICore.myOpenPRsPath.hasPrefix("search/issues?q=is%3Apr+is%3Aopen+author%3A%40me"))
        XCTAssertEqual(CICore.pullPath("o/r", number: 5), "repos/o/r/pulls/5")
    }

    func testLogAttachment() {
        let text = CICore.logAttachment(pr: "o/r#5", title: "Fix it", job: "build", sha: "abcdef123456",
                                        url: "https://x/y", tail: "error: boom")
        XCTAssertEqual(text, "CI check failed: build\nPull request: o/r#5 · Fix it\nCommit: abcdef1\nRun: https://x/y\n\nLast lines of the job log:\nerror: boom")
    }
}
