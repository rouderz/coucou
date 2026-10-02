import XCTest
@testable import Coucou

/// WhaTicket: URLs, auto-accept rules and parsing the API (community version).
final class WhaTicketTests: XCTestCase {
    func testBaseURLs() {
        XCTAssertEqual(WhaTicketRules.normaliseBase(" https://api.x.com/ "), "https://api.x.com")
        XCTAssertNil(WhaTicketRules.normaliseBase("ftp://x"))
    }

    func testHours() {
        XCTAssertTrue(WhaTicketRules.inHours("", minutes: 180))
        XCTAssertTrue(WhaTicketRules.inHours("09:00-18:00", minutes: 9 * 60))
        XCTAssertFalse(WhaTicketRules.inHours("09:00-18:00", minutes: 18 * 60))
        XCTAssertTrue(WhaTicketRules.inHours("22:00-06:00", minutes: 23 * 60))
        XCTAssertTrue(WhaTicketRules.inHours("22:00-06:00", minutes: 5 * 60))
        XCTAssertFalse(WhaTicketRules.inHours("22:00-06:00", minutes: 12 * 60))
        XCTAssertTrue(WhaTicketRules.inHours("nonsense", minutes: 12 * 60))
    }

    func testQueues() {
        XCTAssertTrue(WhaTicketRules.queueAllowed(2, []))
        XCTAssertTrue(WhaTicketRules.queueAllowed(nil, []))
        XCTAssertTrue(WhaTicketRules.queueAllowed(2, [1, 2]))
        XCTAssertFalse(WhaTicketRules.queueAllowed(3, [1, 2]))
        XCTAssertFalse(WhaTicketRules.queueAllowed(nil, [1]))
    }

    func testParsing() {
        let login: [String: Any] = ["token": "t", "user": ["id": 7, "name": "Ana", "queues": [["id": 1, "name": "Sales", "color": "#f00"]]]]
        let parsed = WhaTicketRules.parseLogin(login)
        XCTAssertEqual(parsed?.token, "t")
        XCTAssertEqual(parsed?.account.userId, 7)
        XCTAssertEqual(parsed?.account.queues.first?.name, "Sales")

        let ticket: [String: Any] = ["id": 5, "status": "pending", "unreadMessages": 2, "lastMessage": "Hola", "queueId": 1,
                                     "contact": ["name": "", "number": "5491100"], "queue": ["name": "Sales", "color": "#f00"],
                                     "userId": NSNull(), "updatedAt": "2026-10-02T12:00:00.000Z"]
        let t = WhaTicketRules.parseTicket(ticket)
        XCTAssertEqual(t?.name, "5491100")
        XCTAssertEqual(t?.queue, "Sales")
        XCTAssertEqual(t?.unread, 2)
        XCTAssertNil(t?.userId)
        XCTAssertNotNil(t?.updatedAt)
    }
}
