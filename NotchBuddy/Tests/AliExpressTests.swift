import XCTest
@testable import Coucou

/// AliExpress chat commands and check-in parsing; mirrors windows/src/core/aliexpressCommand.test.ts.
final class AliExpressTests: XCTestCase {
    func testChatCommands() {
        XCTAssertEqual(AliExpressCommand.parse("aliexpress"), .init(op: .sync))
        XCTAssertEqual(AliExpressCommand.parse("/AliExpress pedidos"), .init(op: .sync))
        XCTAssertEqual(AliExpressCommand.parse("aliexpress facturas"), .init(op: .invoices))
        XCTAssertEqual(AliExpressCommand.parse("aliexpress invoices."), .init(op: .invoices))
        XCTAssertEqual(AliExpressCommand.parse("aliexpress factura lp00123456789"), .init(op: .invoice, tracking: "LP00123456789"))
        XCTAssertEqual(AliExpressCommand.parse("aliexpress csv"), .init(op: .csv))
    }

    func testOrdinaryQuestionsGoToTheChat() {
        XCTAssertNil(AliExpressCommand.parse("¿qué pedidos de aliexpress tengo?"))
        XCTAssertNil(AliExpressCommand.parse("aliexpress is slow today"))
        XCTAssertNil(AliExpressCommand.parse("ali facturas"))
        XCTAssertNil(AliExpressCommand.parse("facturas"))
    }

    func testPackagesKeepOnlyWellFormedTracking() {
        let msg: [String: Any] = ["packages": [
            ["tracking": "LP00123456789", "orders": ["8100", "x1"], "items": 3, "total": 31.58, "currency": "USD"],
            ["tracking": "bad tracking!", "orders": ["8101"]],
        ]]
        let list = AliExpressRules.packages(msg)
        XCTAssertEqual(list.map(\.tracking), ["LP00123456789"])
        XCTAssertEqual(list[0].orders, ["8100"])
        XCTAssertEqual(list[0].totalText, "$31.58")
    }
}
