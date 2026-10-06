import XCTest
@testable import Coucou

/// WhaTicket through the browser extension: auto-accept rules, what a check-in may carry, the host manifest.
final class WhaTicketTests: XCTestCase {
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
        XCTAssertEqual(WhaTicketRules.textID(7), "7")
        XCTAssertEqual(WhaTicketRules.textID("q-1"), "q-1")
    }

    func testSnapshotTicketsAreCheckedAndTrimmed() {
        let msg: [String: Any] = [
            "pending": [
                ["id": "6b1c-uuid", "name": "María", "unread": 2, "queueId": "q-1", "queue": "Soporte",
                 "lastMessage": String(repeating: "a", count: 500), "aiHandling": true,
                 "updatedAt": "2026-10-02T12:00:00.000Z"],
                ["id": "../users", "name": "bad"],
                ["name": "no id"],
                ["id": 42, "name": "not text"],
            ],
            "queues": [["id": "q-1", "name": "Soporte", "color": "#0af"], ["id": "a/b"]],
        ]
        let list = WhaTicketRules.tickets(msg, "pending")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "6b1c-uuid")
        XCTAssertEqual(list[0].queue, "Soporte")
        XCTAssertEqual(list[0].unread, 2)
        XCTAssertTrue(list[0].aiHandling)
        XCTAssertEqual(list[0].lastMessage.count, 300)
        XCTAssertNotNil(list[0].updatedAt)
        XCTAssertTrue(WhaTicketRules.tickets([:], "mine").isEmpty)
        XCTAssertEqual(WhaTicketRules.queues(msg), [WhaTicketQueue(id: "q-1", name: "Soporte", color: "#0af")])
    }

    func testIdsAndURLs() {
        XCTAssertTrue(WhaTicketRules.validID("6b1c0e2a-1d2f-4c1b-9a77-0f3c2b1a9e10"))
        XCTAssertFalse(WhaTicketRules.validID("a/b"))
        XCTAssertFalse(WhaTicketRules.validID(""))
        XCTAssertEqual(WhaTicketRules.webURL("t-1")?.absoluteString, "https://app.whaticket.com/tickets/t-1")
        XCTAssertEqual(WhaTicketRules.webURL("../x")?.absoluteString, "https://app.whaticket.com/tickets")
        XCTAssertTrue(WhaTicketRules.errorText("session").contains("expired"))
    }

    /// Coucou for WhaTicket and Coucou for AliExpress share the host; no other extension may start it.
    func testOnlyOurExtensionsMayStartTheHost() throws {
        let text = BrowserExtension.hostManifest(path: "/x/coucou-native-host")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "fr.louisraille.coucou")
        XCTAssertEqual(json["type"] as? String, "stdio")
        XCTAssertEqual(json["path"] as? String, "/x/coucou-native-host")
        XCTAssertEqual(json["allowed_origins"] as? [String], [
            "chrome-extension://jcdddeeehgafiakcgaabpiocfdijekce/",
            "chrome-extension://fkdhifnmpmkjgkaacobdgohnnnlpgmil/",
        ])
    }
}
