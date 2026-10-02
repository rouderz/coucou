import XCTest
@testable import Coucou

/// Skills (Settings → Skills and "/" in the chat): front matter, names, GitHub links, matching.
final class SkillsTests: XCTestCase {
    func testFrontMatterPlainAndQuoted() {
        let meta = SkillFiles.frontMatter("---\nname: pdf-tools\ndescription: \"Read PDFs: text, tables\"\n---\n# Body")
        XCTAssertEqual(meta.name, "pdf-tools")
        XCTAssertEqual(meta.description, "Read PDFs: text, tables")
    }

    func testFrontMatterFoldedBlockAndBOM() {
        let meta = SkillFiles.frontMatter("\u{feff}---\r\nname: x\r\ndescription: >\r\n  First line\r\n  second line\r\nlicense: MIT\r\n---\r\n")
        XCTAssertEqual(meta.name, "x")
        XCTAssertEqual(meta.description, "First line second line")
        XCTAssertNil(SkillFiles.frontMatter("# Just markdown").name)
    }

    func testFolderNamesAreSafe() {
        XCTAssertEqual(SkillFiles.folderName("My Skill v2.0"), "my-skill-v2-0")
        XCTAssertEqual(SkillFiles.folderName("../etc"), "etc")
        XCTAssertEqual(SkillFiles.folderName("  "), "skill")
    }

    func testScriptsAreSpotted() {
        XCTAssertTrue(SkillFiles.isScript("scripts/run.txt"))
        XCTAssertTrue(SkillFiles.isScript("tool/convert.py"))
        XCTAssertFalse(SkillFiles.isScript("reference/notes.md"))
    }

    func testGitHubLinks() {
        XCTAssertEqual(SkillFiles.githubArchive("https://github.com/anthropics/skills")?.url.absoluteString,
                       "https://github.com/anthropics/skills/archive/HEAD.zip")
        let folder = SkillFiles.githubArchive("https://github.com/o/r/tree/main/skills/pdf/")
        XCTAssertEqual(folder?.url.absoluteString, "https://github.com/o/r/archive/main.zip")
        XCTAssertEqual(folder?.subpath, "skills/pdf")
        XCTAssertEqual(SkillFiles.githubArchive("https://github.com/o/r/blob/main/a/SKILL.md")?.subpath, "a")
        XCTAssertNil(SkillFiles.githubArchive("https://example.com/o/r"))
        XCTAssertNil(SkillFiles.githubArchive("https://github.com/o/r/tree/main/../x"))
    }

    func testPluginPathsBothLayouts() {
        let v2: [String: Any] = ["version": 2, "plugins": ["docs@market": [["installPath": "/p/docs/1.0"]]]]
        let v1: [String: Any] = ["plugins": ["lint@m": ["installPath": "/p/lint"]]]
        XCTAssertEqual(SkillFiles.pluginPaths(v2).map { "\($0.0) \($0.1)" }, ["docs /p/docs/1.0"])
        XCTAssertEqual(SkillFiles.pluginPaths(v1).map { "\($0.0) \($0.1)" }, ["lint /p/lint"])
    }

    func testMatchAndPrompt() {
        func skill(_ name: String, _ description: String = "", enabled: Bool = true) -> SkillInfo {
            SkillInfo(name: name, description: description, source: .personal, origin: nil, path: "/s/\(name)",
                      enabled: enabled, editable: true, hasScripts: false)
        }
        let all = [skill("pdf", "Read PDF files"), skill("xlsx", "Spreadsheets, reads pdf exports too"), skill("old", enabled: false)]
        XCTAssertEqual(SkillFiles.match(all, typed: "/").map(\.name), ["pdf", "xlsx"])
        XCTAssertEqual(SkillFiles.match(all, typed: "/pd").map(\.name), ["pdf", "xlsx"])
        XCTAssertEqual(SkillFiles.match(all, typed: "/XL").map(\.name), ["xlsx"])
        XCTAssertTrue(SkillFiles.match(all, typed: "/old").isEmpty)
        let text = SkillFiles.withSkill(name: "pdf", path: "/s/pdf", content: "  # PDF\nSteps  ", query: "summarise it")
        XCTAssertTrue(text.hasPrefix("Use the skill \"pdf\" for this request (its folder: /s/pdf)."))
        XCTAssertTrue(text.contains("<skill>\n# PDF\nSteps\n</skill>"))
        XCTAssertTrue(text.hasSuffix("Request: summarise it"))
    }

    func testFindsNestedSkillsAndCopiesWithoutSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString.prefix(6))")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("pack/a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("pack/b/scripts"), withIntermediateDirectories: true)
        try "---\nname: a\n---".write(to: root.appendingPathComponent("pack/a/SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: b\n---".write(to: root.appendingPathComponent("pack/b/SKILL.md"), atomically: true, encoding: .utf8)
        try "echo".write(to: root.appendingPathComponent("pack/b/scripts/x.sh"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("pack/b/link").path, withDestinationPath: "/etc/hosts")
        XCTAssertEqual(SkillFiles.findSkillDirs(root).map(\.lastPathComponent), ["a", "b"])
        let copy = root.appendingPathComponent("copy")
        try SkillFiles.copyDir(root.appendingPathComponent("pack/b"), to: copy)
        XCTAssertEqual(SkillFiles.listFiles(copy), ["SKILL.md", "scripts/x.sh"])
    }
}
