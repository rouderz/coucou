import XCTest
@testable import Coucou

/// The integrations' response parsers, fed with recorded API responses (#12): if a service
/// changes its format, these fail before the cards go blank.
final class PollerParsingTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testVercelDeployment() throws {
        let d = try json("""
        {"uid":"dpl_1","name":"shopit-web","url":"shopit-abc.vercel.app","state":"READY",
         "createdAt":1759300000000,"buildingAt":1759300005000,"ready":1759300077000,
         "meta":{"githubCommitMessage":"Fix cart total","githubCommitRef":"main"}}
        """)
        let dep = try XCTUnwrap(VercelPoller.parseDeployment(d))
        XCTAssertEqual(dep.projectName, "shopit-web")
        XCTAssertTrue(dep.isSuccess)
        XCTAssertEqual(dep.commitMessage, "Fix cart total")
        XCTAssertEqual(dep.branch, "main")
        XCTAssertEqual(dep.buildSeconds ?? 0, 72, accuracy: 0.01)
        XCTAssertNil(VercelPoller.parseDeployment(["name": "x"]), "no uid → skipped")
    }

    func testStripeCharge() throws {
        let c = try json("""
        {"id":"ch_1","amount":4999,"currency":"eur","status":"succeeded","created":1759300000,
         "description":null,"billing_details":{"name":"Ada Lovelace"}}
        """)
        let p = try XCTUnwrap(StripePoller.parseCharge(c))
        XCTAssertEqual(p.amountFormatted, "49.99")
        XCTAssertEqual(p.description, "Ada Lovelace", "falls back to the billing name")
        XCTAssertTrue(p.isSuccess)
    }

    func testNotionPage() throws {
        let page = try json("""
        {"object":"page","id":"p1","url":"https://www.notion.so/Plan-p1","last_edited_time":"2026-10-01T12:00:00.000Z",
         "icon":{"type":"emoji","emoji":"🗺️"},
         "properties":{"Name":{"type":"title","title":[{"plain_text":"Roadmap"}]}}}
        """)
        let p = try XCTUnwrap(NotionPoller.parsePage(page))
        XCTAssertEqual(p.title, "Roadmap")
        XCTAssertEqual(p.emoji, "🗺️")
        XCTAssertEqual(p.url, "https://www.notion.so/Plan-p1")
    }

    func testResendEmail() throws {
        let e = try json("""
        {"id":"em_1","to":["ada@example.com"],"subject":"Welcome","created_at":"2026-10-01 12:00:00.123+00",
         "last_event":"delivered"}
        """)
        let email = try XCTUnwrap(ResendPoller.parseEmail(e))
        XCTAssertEqual(email.to, ["ada@example.com"])
        XCTAssertEqual(email.lastEvent, "delivered")
        XCTAssertEqual(ResendPoller.parseEmail(["id": "x", "created_at": "2026-10-01T12:00:00Z", "to": "solo@x.com"])?.to,
                       ["solo@x.com"], "a single recipient as a string")
    }

    func testCalcomBooking() throws {
        let b = try json("""
        {"id":"42","title":"Intro call","status":"accepted","start":"2026-10-02T15:00:00.000Z","end":"2026-10-02T15:30:00.000Z",
         "attendees":[{"name":"Grace","email":"grace@example.com"}],"responses":{"notes":{"value":"About the API"}}}
        """)
        let booking = try XCTUnwrap(CalcomPoller.parseBooking(b))
        XCTAssertEqual(booking.id, 42)
        XCTAssertEqual(booking.attendeeName, "Grace")
        XCTAssertEqual(booking.attendeeNotes, "About the API")
        XCTAssertEqual(booking.endTime.timeIntervalSince(booking.startTime), 1800, accuracy: 1)
    }

    func testN8nExecutionDetails() throws {
        let failed = try json("""
        {"data":{"resultData":{"error":{"message":"Timed out after 30s","node":{"name":"Gmail"}}}}}
        """)
        XCTAssertEqual(N8nPoller.parseDetail(from: failed, success: false), "Gmail\nTimed out after 30s")

        let ok = try json("""
        {"data":{"resultData":{"lastNodeExecuted":"Slack","runData":{"Slack":[{"data":{"main":[[{"json":{"ok":true}}]]}}]}}}}
        """)
        XCTAssertEqual(N8nPoller.parseDetail(from: ok, success: true), "→ Slack · 1 item\nok: 1")
    }

    func testPlanUsageWindow() throws {
        let w = try XCTUnwrap(PlanUsagePoller.window(["utilization": 81.0, "resets_at": "2026-10-01T18:00:00.123456+00:00"]))
        XCTAssertEqual(w.percent, 81)
        XCTAssertEqual(ISO8601DateFormatter().string(from: w.resetsAt), "2026-10-01T18:00:00Z")
        XCTAssertNil(PlanUsagePoller.window(["utilization": 10.0]), "no reset time → no bar")
    }
}
