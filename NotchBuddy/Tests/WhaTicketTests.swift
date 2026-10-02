import XCTest
@testable import Coucou

/// WhaTicket: URLs, auto-accept rules and both APIs (whaticket.com and self-hosted).
final class WhaTicketTests: XCTestCase {
    func testBaseURLs() {
        XCTAssertEqual(WhaTicketRules.normaliseBase(" https://api.x.com/ "), "https://api.x.com")
        XCTAssertNil(WhaTicketRules.normaliseBase("ftp://x"))
        XCTAssertEqual(WhaTicketRules.cloudBase(nil), "https://api.whaticket.com/api/v1")
        XCTAssertEqual(WhaTicketRules.cloudBase("https://api.whaticket.com/"), "https://api.whaticket.com/api/v1")
        XCTAssertEqual(WhaTicketRules.cloudBase("https://api.whaticket.com/api/v1"), "https://api.whaticket.com/api/v1")
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
        XCTAssertTrue(WhaTicketRules.queueAllowed("x", []))
        XCTAssertTrue(WhaTicketRules.queueAllowed(nil, []))
        XCTAssertTrue(WhaTicketRules.queueAllowed("b", ["a", "b"]))
        XCTAssertFalse(WhaTicketRules.queueAllowed("c", ["a", "b"]))
        XCTAssertFalse(WhaTicketRules.queueAllowed(nil, ["a"]))
    }

    func testSelfHostedParsing() {
        let login: [String: Any] = ["token": "t", "user": ["id": 7, "name": "Ana", "queues": [["id": 1, "name": "Sales", "color": "#f00"]]]]
        let parsed = WhaTicketRules.parseLogin(login)
        XCTAssertEqual(parsed?.token, "t")
        XCTAssertEqual(parsed?.account.userId, "7")
        XCTAssertEqual(parsed?.account.queues.first?.id, "1")

        let ticket: [String: Any] = ["id": 5, "status": "pending", "unreadMessages": 2, "lastMessage": "Hola", "queueId": 1,
                                     "contact": ["name": "", "number": "5491100"], "queue": ["id": 1, "name": "Sales", "color": "#f00"],
                                     "userId": NSNull(), "updatedAt": "2026-10-02T12:00:00.000Z"]
        let t = WhaTicketRules.parseTicket(ticket)
        XCTAssertEqual(t?.id, "5")
        XCTAssertEqual(t?.name, "5491100")
        XCTAssertEqual(t?.queue, "Sales")
        XCTAssertEqual(t?.queueId, "1")
        XCTAssertNil(t?.userId)
        XCTAssertNotNil(t?.updatedAt)
    }

    func testWhaticketComParsing() {
        let queues = [WhaTicketQueue(id: "q-1", name: "Soporte", color: "#0af")]
        let ticket: [String: Any] = ["id": "6b1c-uuid", "status": "pending", "queueId": "q-1", "userId": NSNull(),
                                     "contact": ["name": "María"], "lastMessage": "Hola"]
        let t = WhaTicketRules.parseTicket(ticket, queues: queues)
        XCTAssertEqual(t?.id, "6b1c-uuid")
        XCTAssertEqual(t?.queue, "Soporte")
        XCTAssertEqual(t?.queueColor, "#0af")

        let users: [String: Any] = ["users": [["id": "u-1", "email": "Ana@Empresa.com", "name": "Ana"]]]
        XCTAssertEqual(WhaTicketRules.findUser(users, email: "ana@empresa.com ")?["id"] as? String, "u-1")
        XCTAssertNil(WhaTicketRules.findUser(users, email: "otro@x.com"))

        XCTAssertEqual(WhaTicketRules.missingPermissions(["permissions": ["tickets:view", "tickets:viewAll"]]),
                       ["tickets:viewPending", "tickets:transfer", "users:view"])
        XCTAssertTrue(WhaTicketRules.missingPermissions(["name": "x"]).isEmpty)
        XCTAssertEqual(WhaTicketRules.list([["id": 1], ["id": 2]], "queues").count, 2)
    }

    func testErrorsNameTheCause() {
        XCTAssertTrue(WhaTicketRules.describe(code: 401, body: ["error": "ERR_SHOULD_LOGIN_BY_AUTH_CODE"]).contains("API token"))
        XCTAssertTrue(WhaTicketRules.describe(code: 429, body: nil).contains("too many"))
    }
}
