import XCTest
@testable import Coucou

/// Quick capture (#118): the line parser, the preview chip, the issueCreate input and the two-step Enter flow.
/// Mirrors windows/src/core/capture.test.ts.
final class QuickCaptureTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// Saturday 3 Oct 2026.
    private var saturday: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 15))! }
    private let teams = [LinearTeam(id: "t-sho", key: "SHO", name: "Shop"), LinearTeam(id: "t-eng", key: "ENG", name: "Engineering")]

    private func parse(_ line: String) -> ParsedCapture { QuickCapture.parse(line, now: saturday, calendar: cal) }

    func testParsesTheExampleFromTheIssue() {
        XCTAssertEqual(parse("Fix the cart total rounding #SHO p2 @me"),
                       ParsedCapture(title: "Fix the cart total rounding", teamKey: "SHO", priority: 2, assignToMe: true, dueDate: nil))
    }

    func testTokensAnywhereCaseInsensitive() {
        let p = parse("  #sho   P1 fix  @ME the thing !tomorrow ")
        XCTAssertEqual(p.title, "fix the thing")
        XCTAssertEqual(p.teamKey, "SHO")
        XCTAssertEqual(p.priority, 1)
        XCTAssertTrue(p.assignToMe)
        XCTAssertEqual(p.dueDate, "2026-10-04")
    }

    func testLookalikesStayInTheTitle() {
        let line = "Handle issue #123 and p5 and p12 and @mex !someday email@me.com"
        let p = parse(line)
        XCTAssertEqual(p.title, line)
        XCTAssertNil(p.teamKey)
        XCTAssertEqual(p.priority, 0)
        XCTAssertFalse(p.assignToMe)
        XCTAssertNil(p.dueDate)
    }

    func testLastTokenOfAKindWins() {
        let p = parse("a p4 b p1 #ENG #SHO")
        XCTAssertEqual(p.priority, 1)
        XCTAssertEqual(p.teamKey, "SHO")
        XCTAssertEqual(parse("   ").title, "")
    }

    func testDueDates() {
        func due(_ w: String, _ now: Date? = nil) -> String? { QuickCapture.parseDue(w, now: now ?? saturday, calendar: cal) }
        XCTAssertEqual(due("today"), "2026-10-03")
        XCTAssertEqual(due("fri"), "2026-10-09")
        XCTAssertEqual(due("Friday"), "2026-10-09")
        XCTAssertEqual(due("sat"), "2026-10-10")   // same weekday means next week
        XCTAssertEqual(due("sun"), "2026-10-04")
        XCTAssertEqual(due("mon", cal.date(from: DateComponents(year: 2026, month: 12, day: 31))!), "2027-01-04")
        XCTAssertNil(due("2026-02-30"))
        XCTAssertEqual(due("2026-11-15"), "2026-11-15")
        XCTAssertNil(due("later"))
    }

    func testChipPicksTheTeam() {
        func chip(_ line: String, _ teams: [LinearTeam]? = nil, _ def: String? = nil) -> PreviewChip {
            PreviewChip.make(parse(line), teams: teams ?? self.teams, defaultTeamKey: def)
        }
        XCTAssertEqual(chip("x #sho", nil, "ENG").team?.id, "t-sho")
        XCTAssertEqual(chip("x", nil, "eng").team?.id, "t-eng")
        XCTAssertEqual(chip("x", [teams[0]]).team?.id, "t-sho")
        XCTAssertEqual(chip("x").problems, [.noTeam])
        XCTAssertEqual(chip("x #zzz").problems, [.unknownTeam])
        XCTAssertEqual(chip("#sho p1").problems, [.emptyTitle])
        XCTAssertEqual(chip("x", []).problems, [.noTeamsLoaded])
        XCTAssertFalse(chip("x").ready)
        XCTAssertTrue(chip("Fix it p3 @me", nil, "SHO").ready)
    }

    func testIssueCreateInputHasOnlyWhatWasTyped() {
        let chip = PreviewChip.make(parse("Fix it #SHO p2 @me !today"), teams: teams, defaultTeamKey: nil)
        let input = LinearAPI.issueCreateInput(chip, viewerID: "u-1")
        XCTAssertEqual(input?["teamId"] as? String, "t-sho")
        XCTAssertEqual(input?["title"] as? String, "Fix it")
        XCTAssertEqual(input?["priority"] as? Int, 2)
        XCTAssertEqual(input?["assigneeId"] as? String, "u-1")
        XCTAssertEqual(input?["dueDate"] as? String, "2026-10-03")
        XCTAssertNil(LinearAPI.issueCreateInput(chip, viewerID: nil), "@me needs the viewer id")

        let bare = PreviewChip.make(parse("Fix it"), teams: teams, defaultTeamKey: "ENG")
        XCTAssertEqual(LinearAPI.issueCreateInput(bare, viewerID: nil)?.count, 2)
        XCTAssertNil(LinearAPI.issueCreateInput(PreviewChip.make(parse(""), teams: teams, defaultTeamKey: "ENG"), viewerID: nil))
    }

    func testResponses() {
        let t = LinearAPI.parseTeams(["viewer": ["id": "u-1"],
                                      "teams": ["nodes": [["id": "a", "key": "SHO", "name": "Shop"], ["id": 3], ["id": "b", "key": "ENG"]]]])
        XCTAssertEqual(t.viewerID, "u-1")
        XCTAssertEqual(t.teams, [LinearTeam(id: "a", key: "SHO", name: "Shop"), LinearTeam(id: "b", key: "ENG", name: "ENG")])
        XCTAssertNil(LinearAPI.parseTeams([:]).viewerID)

        let ok = CreatedIssue(["issueCreate": ["success": true, "issue": ["id": "i", "identifier": "SHO-9", "title": "T",
                                                                          "url": "https://linear.app/x", "branchName": "me/sho-9-t"]]])
        XCTAssertEqual(ok?.identifier, "SHO-9")
        XCTAssertEqual(ok?.branchToCopy, "me/sho-9-t")
        XCTAssertNil(CreatedIssue(["issueCreate": ["success": false]]))
        XCTAssertNil(CreatedIssue([:]))
        XCTAssertEqual(CreatedIssue(id: "i", identifier: "SHO-9", title: "", url: "", branchName: nil).branchToCopy, "sho-9")
    }

    func testNothingIsCreatedBeforeTheSecondEnter() {
        let ctx = CaptureFlow.Context(teams: teams, defaultTeamKey: "ENG", now: saturday)
        var s = CaptureFlow.State.initial
        var effects: [CaptureFlow.Effect] = []
        func send(_ e: CaptureFlow.Event) {
            let r = CaptureFlow.reduce(s, e, ctx)
            s = r.state
            if let effect = r.effect { effects.append(effect) }
        }
        send(.enter)   // empty line
        XCTAssertEqual(s, .editing(line: ""))
        send(.type("Fix cart #SHO p2"))
        send(.enter)   // first Enter: preview only
        guard case .preview = s else { return XCTFail("expected a preview") }
        XCTAssertTrue(effects.isEmpty)
        send(.type("Fix cart #SHO p1"))   // editing un-confirms the preview
        guard case .editing = s else { return XCTFail("expected editing") }
        send(.enter)
        XCTAssertTrue(effects.isEmpty)
        send(.enter)   // second Enter: create
        guard case .creating(_, let chip) = s else { return XCTFail("expected creating") }
        XCTAssertEqual(effects, [.create(chip)])
        send(.enter)   // no double send
        send(.type("other"))
        XCTAssertEqual(effects.count, 1)
        send(.created(CreatedIssue(id: "i", identifier: "SHO-1", title: "t", url: "u", branchName: nil)))
        guard case .done = s else { return XCTFail("expected done") }
        send(.enter)
        XCTAssertEqual(effects.last, .close)
    }

    func testProblemsBlockConfirmationAndFailureNeedsANewOne() {
        let noDefault = CaptureFlow.Context(teams: teams, defaultTeamKey: nil, now: saturday)
        var r = CaptureFlow.reduce(.editing(line: "Fix cart"), .enter, noDefault)
        guard case .preview = r.state else { return XCTFail("expected a preview") }
        r = CaptureFlow.reduce(r.state, .enter, noDefault)   // no team: can't be confirmed
        guard case .preview = r.state else { return XCTFail("still a preview") }
        XCTAssertNil(r.effect)
        r = CaptureFlow.reduce(r.state, .escape, noDefault)
        XCTAssertEqual(r.state, .editing(line: "Fix cart"))
        XCTAssertEqual(CaptureFlow.reduce(r.state, .escape, noDefault).effect, .close)

        let ctx = CaptureFlow.Context(teams: teams, defaultTeamKey: nil, now: saturday)
        var s = CaptureFlow.State.editing(line: "Fix cart #SHO")
        s = CaptureFlow.reduce(s, .enter, ctx).state
        s = CaptureFlow.reduce(s, .enter, ctx).state
        s = CaptureFlow.reduce(s, .failed("Can't reach Linear"), ctx).state
        guard case .failed = s else { return XCTFail("expected failed") }
        r = CaptureFlow.reduce(s, .enter, ctx)   // retry goes through the preview again
        guard case .preview = r.state else { return XCTFail("expected a preview") }
        XCTAssertNil(r.effect)
    }
}
