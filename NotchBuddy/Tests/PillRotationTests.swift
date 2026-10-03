import XCTest
@testable import Coucou

final class PillRotationTests: XCTestCase {
    private let ids = ["a", "b", "c", "d", "e", "f"]

    func testFewPillsAreAllShown() {
        XCTAssertEqual(PillRotation.visible(ids: ["a", "b", "c"], offset: 7), ["a", "b", "c"])
        XCTAssertEqual(PillRotation.visible(ids: ["a", "b", "c", "d"], offset: 3), ["a", "b", "c", "d"])
    }

    func testRotationAdvancesAndWraps() {
        XCTAssertEqual(PillRotation.visible(ids: ids, offset: 0), ["a", "b", "c", "d"])
        XCTAssertEqual(PillRotation.visible(ids: ids, offset: 1), ["b", "c", "d", "e"])
        XCTAssertEqual(PillRotation.visible(ids: ids, offset: 3), ["a", "d", "e", "f"])
        XCTAssertEqual(PillRotation.visible(ids: ids, offset: 6), ["a", "b", "c", "d"])
    }

    func testPinnedNeverRotateOut() {
        for offset in 0..<12 {
            XCTAssertTrue(PillRotation.visible(ids: ids, pinned: ["f"], offset: offset).contains("f"))
        }
        XCTAssertEqual(PillRotation.visible(ids: ids, pinned: ["f"], offset: 0), ["a", "b", "c", "f"])
    }

    func testNewsJumpsIntoView() {
        for offset in 0..<12 {
            XCTAssertTrue(PillRotation.visible(ids: ids, news: ["e"], offset: offset).contains("e"))
        }
    }

    func testPinnedWinOverNewsAndLimitHolds() {
        let result = PillRotation.visible(ids: ids, pinned: ["a", "b", "c", "d", "e"], news: ["f"], offset: 2)
        XCTAssertEqual(result, ["a", "b", "c", "d"])
        XCTAssertEqual(PillRotation.visible(ids: ids, news: ["a", "b", "c", "d", "e", "f"], offset: 0).count, 4)
    }

    func testNegativeOffsetAndEmptyInput() {
        XCTAssertEqual(PillRotation.visible(ids: ids, offset: -1).count, 4)
        XCTAssertEqual(PillRotation.visible(ids: [], offset: 3), [])
    }
}
