import XCTest
@testable import Coucou

/// Graphify (Settings → Graphify): finding the CLI, versions, stale detection, query trimming.
/// Same cases as windows/src/core/graphify.test.ts.
final class GraphifyTests: XCTestCase {
    func testCandidatesKeepPathFirstAndDropDuplicates() {
        let list = GraphifyLogic.cliCandidates(home: "/home/u", env: ["PATH": "/usr/bin::/home/u/.local/bin", "UV_TOOL_BIN_DIR": "/opt/uv"])
        XCTAssertEqual(list, ["/usr/bin/graphify", "/home/u/.local/bin/graphify", "/opt/uv/graphify"])
    }

    func testVersions() {
        XCTAssertEqual(GraphifyLogic.parseVersion("graphify 0.4.2\n"), GraphifyVersion(major: 0, minor: 4, patch: 2))
        XCTAssertEqual(GraphifyLogic.parseVersion("v1.2"), GraphifyVersion(major: 1, minor: 2, patch: 0))
        XCTAssertNil(GraphifyLogic.parseVersion("command not found"))
        XCTAssertTrue(GraphifyVersion(major: 0, minor: 4, patch: 2) < GraphifyVersion(major: 0, minor: 10, patch: 0))
    }

    func testCLIStatus() {
        let min = GraphifyVersion(major: 0, minor: 4, patch: 0)
        XCTAssertEqual(GraphifyLogic.cliStatus(path: nil, versionOutput: nil), .missing)
        XCTAssertEqual(GraphifyLogic.cliStatus(path: "/x/graphify", versionOutput: "oops"), .unknown(path: "/x/graphify"))
        XCTAssertEqual(GraphifyLogic.cliStatus(path: "/x/graphify", versionOutput: nil), .unknown(path: "/x/graphify"))
        if case .old = GraphifyLogic.cliStatus(path: "/x/graphify", versionOutput: "graphify 0.3.0", min: min) {} else { XCTFail("old") }
        if case .ok = GraphifyLogic.cliStatus(path: "/x/graphify", versionOutput: "graphify 0.4.0", min: min) {} else { XCTFail("ok") }
    }

    func testStampRoundTripAndBadInput() {
        XCTAssertEqual(GraphifyLogic.parseStamp(GraphifyLogic.stampText(commit: "abc1234", builtAt: 99)),
                       GraphifyStamp(commit: "abc1234", builtAt: 99))
        XCTAssertNil(GraphifyLogic.parseStamp("{"))
        XCTAssertNil(GraphifyLogic.parseStamp("{\"commit\":\"--output=/etc/x\"}"))
    }

    func testGraphCountsAreBestEffort() {
        let a = GraphifyLogic.parseGraphCounts("{\"nodes\":[1,2,3],\"edges\":[1]}")
        XCTAssertEqual(a?.nodes, 3)
        XCTAssertEqual(a?.edges, 1)
        XCTAssertEqual(GraphifyLogic.parseGraphCounts("{\"nodes\":[1],\"links\":[1,2]}")?.edges, 2)
        XCTAssertNil(GraphifyLogic.parseGraphCounts("[]"))
        XCTAssertNil(GraphifyLogic.parseGraphCounts("nope"))
    }

    func testGitArgumentsRejectNonCommits() {
        XCTAssertEqual(GraphifyLogic.changedFilesArgs(commit: "abc1234"), ["diff", "--name-only", "abc1234..HEAD"])
        XCTAssertNil(GraphifyLogic.changedFilesArgs(commit: "--help"))
        XCTAssertEqual(GraphifyLogic.builtAtCommitArgs(graphMtime: 1_700_000_000.9), ["rev-list", "-1", "--before=1700000000", "HEAD"])
    }

    func testStaleDetectionIgnoresGraphifyOut() {
        let changed = GraphifyLogic.parseChangedFiles("src\\a.ts\nsrc/b.ts\ngraphify-out/graph.json\n\ngraphify-out\n")
        XCTAssertEqual(changed, ["src/a.ts", "src/b.ts"])
        XCTAssertEqual(GraphifyLogic.graphStatus(hasGraph: true, changed: changed), .stale(changed: 2, sample: ["src/a.ts", "src/b.ts"]))
        XCTAssertEqual(GraphifyLogic.graphStatus(hasGraph: true, changed: GraphifyLogic.parseChangedFiles("graphify-out/graph.json\n")), .fresh)
        XCTAssertEqual(GraphifyLogic.graphStatus(hasGraph: true, changed: nil), .unknown)
        XCTAssertEqual(GraphifyLogic.graphStatus(hasGraph: false, changed: []), .none)
        let many = (0..<9).map { "f\($0)" }
        XCTAssertEqual(GraphifyLogic.graphStatus(hasGraph: true, changed: many, sampleSize: 3), .stale(changed: 9, sample: ["f0", "f1", "f2"]))
    }

    func testQueryOutputIsCleanedAndCappedAtALine() {
        XCTAssertEqual(GraphifyLogic.trimQueryOutput("\u{1B}[1mNode\u{1B}[0m: A\r\n  --> B\r\n"), "Node: A\n  --> B")
        let big = (0..<200).map { "  --> Node\($0) [uses] [INFERRED]" }.joined(separator: "\n")
        let out = GraphifyLogic.trimQueryOutput(big, cap: 500)
        XCTAssertLessThanOrEqual(out.unicodeScalars.count, 500)
        XCTAssertTrue(out.hasPrefix("--> Node0 "))
        XCTAssertTrue(out.hasSuffix("characters)"))
        let body = out.components(separatedBy: "\n…")[0]
        XCTAssertTrue(body.components(separatedBy: "\n").allSatisfy { $0.hasSuffix("[INFERRED]") })
        let one = GraphifyLogic.trimQueryOutput(String(repeating: "x", count: 1000), cap: 100)
        XCTAssertEqual(one.unicodeScalars.count, 100)
        XCTAssertTrue(one.hasSuffix("…"))
        XCTAssertEqual(GraphifyLogic.trimQueryOutput("short", cap: 100), "short")
    }
}
