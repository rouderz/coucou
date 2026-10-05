import Foundation

// Quick capture (#118): one line becomes a Linear issue.
//
//   Fix the cart total rounding #SHO p2 @me !fri
//
// Pure logic: the line parser, the preview chip, the issueCreate variables and the
// two-step Enter flow. Mirrors windows/src/core/capture.ts (which has the tests run in CI
// on Linux); keep the two in step. Nothing is created until the second Enter / click:
// `CaptureFlow.reduce` only returns `.create` from the preview phase.

struct ParsedCapture: Equatable, Sendable {
    var title = ""
    /// Team key as typed, upper-cased ("SHO"); nil = the default team.
    var teamKey: String?
    /// Linear priority: 1 urgent, 2 high, 3 medium, 4 low; 0 = none.
    var priority = 0
    var assignToMe = false
    /// "YYYY-MM-DD" (local calendar day).
    var dueDate: String?
}

struct LinearTeam: Equatable, Sendable {
    let id: String
    let key: String
    let name: String
}

enum QuickCapture {
    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let weekdaysLong = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "today", "tomorrow", a weekday ("fri", "friday": the next one, never today) or "YYYY-MM-DD".
    static func parseDue(_ word: String, now: Date, calendar: Calendar = .current) -> String? {
        let w = word.lowercased()
        let today = calendar.startOfDay(for: now)
        func shifted(_ days: Int) -> String? {
            calendar.date(byAdding: .day, value: days, to: today).map { isoDay($0, calendar: calendar) }
        }
        if w == "today" || w == "tod" { return isoDay(today, calendar: calendar) }
        if w == "tomorrow" || w == "tom" { return shifted(1) }
        if let wd = weekdays.firstIndex(of: w) ?? weekdaysLong.firstIndex(of: w) {
            let current = calendar.component(.weekday, from: today) - 1   // 0 = Sunday
            return shifted(((wd - current + 6) % 7) + 1)
        }
        let parts = w.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
           let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
           isoDay(date, calendar: calendar) == w {   // rejects 2026-02-30 (the calendar rolls it over)
            return w
        }
        return nil
    }

    /// A word is a token only when it matches exactly (`#SHO`, `p2`, `@me`, `!fri`); otherwise it
    /// stays in the title. If a token kind appears twice the last one wins.
    static func parse(_ line: String, now: Date = .now, calendar: Calendar = .current) -> ParsedCapture {
        var out = ParsedCapture()
        var kept: [String] = []
        for word in line.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if word.hasPrefix("#"), isTeamKey(word.dropFirst()) {
                out.teamKey = word.dropFirst().uppercased()
            } else if word.count == 2, word.first == "p" || word.first == "P",
                      let n = Int(word.dropFirst()), (1...4).contains(n) {
                out.priority = n
            } else if word.lowercased() == "@me" {
                out.assignToMe = true
            } else if word.hasPrefix("!"), let due = parseDue(String(word.dropFirst()), now: now, calendar: calendar) {
                out.dueDate = due
            } else {
                kept.append(word)
            }
        }
        out.title = kept.joined(separator: " ")
        return out
    }

    /// A letter, then 1 to 9 letters or digits (ASCII).
    private static func isTeamKey(_ s: Substring) -> Bool {
        guard (2...10).contains(s.count), let first = s.unicodeScalars.first,
              first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
}

// MARK: - Preview chip

struct PreviewChip: Equatable, Sendable {
    enum Problem: Equatable, Sendable { case emptyTitle, unknownTeam, noTeam, noTeamsLoaded }

    var team: LinearTeam?
    var title: String
    var priority: Int
    var assignToMe: Bool
    var dueDate: String?
    var problems: [Problem]

    /// True only when the issue could be created as shown.
    var ready: Bool { problems.isEmpty && team != nil }

    var priorityLabel: String {
        switch priority {
        case 1: return L("Urgent")
        case 2: return L("High")
        case 3: return L("Medium")
        case 4: return L("Low")
        default: return L("No priority")
        }
    }

    /// The team: the `#KEY` typed, else the default team from Settings, else (when there's only one) that one.
    static func make(_ p: ParsedCapture, teams: [LinearTeam], defaultTeamKey: String?) -> PreviewChip {
        var problems: [Problem] = []
        var team: LinearTeam?
        let wanted = p.teamKey ?? defaultTeamKey.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        if teams.isEmpty {
            problems.append(.noTeamsLoaded)
        } else if let wanted {
            team = teams.first { $0.key.uppercased() == wanted }
            if team == nil { problems.append(.unknownTeam) }
        } else if teams.count == 1 {
            team = teams[0]
        } else {
            problems.append(.noTeam)
        }
        if p.title.isEmpty { problems.append(.emptyTitle) }
        return PreviewChip(team: team, title: p.title, priority: p.priority, assignToMe: p.assignToMe,
                           dueDate: p.dueDate, problems: problems)
    }
}

// MARK: - Linear requests

struct CreatedIssue: Equatable, Sendable {
    let id: String
    let identifier: String
    let title: String
    let url: String
    let branchName: String?

    init?(_ data: [String: Any]) {
        guard let result = data["issueCreate"] as? [String: Any], result["success"] as? Bool == true,
              let issue = result["issue"] as? [String: Any],
              let id = issue["id"] as? String, let identifier = issue["identifier"] as? String else { return nil }
        self.id = id
        self.identifier = identifier
        self.title = issue["title"] as? String ?? ""
        self.url = issue["url"] as? String ?? "https://linear.app"
        self.branchName = issue["branchName"] as? String
    }

    init(id: String, identifier: String, title: String, url: String, branchName: String?) {
        self.id = id; self.identifier = identifier; self.title = title; self.url = url; self.branchName = branchName
    }

    /// Branch to copy for "Start a Claude Code session on it": Linear's own name, else
    /// "<identifier>-<slug of the title>".
    var branchToCopy: String {
        if let branchName, !branchName.isEmpty { return branchName }
        let tail = QuickCapture.slug(title)
        return tail.isEmpty ? identifier.lowercased() : "\(identifier.lowercased())-\(tail)"
    }
}

// MARK: - Context and chat drafts

/// What goes into the issue's description when the user attaches it: a chip label and Markdown.
struct CaptureAttachment: Equatable, Sendable {
    let label: String
    let text: String
}

extension QuickCapture {
    private static let maxSelection = 4000

    /// "Fix the cart total rounding" → "fix-the-cart-total-rounding": ASCII, accents dropped, at most 50 characters.
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        for u in folded.unicodeScalars {
            if u.isASCII, CharacterSet.alphanumerics.contains(u) {
                out.unicodeScalars.append(u)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out.append("-")
            }
        }
        out = String(out.prefix(50))
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// The editor's file (and selection).
    static func describeCode(file: String, line: Int?, selection: String?) -> CaptureAttachment? {
        guard !file.isEmpty else { return nil }
        let name = (file as NSString).lastPathComponent
        var text = "`" + (line.map { "\(file):\($0)" } ?? file) + "`"
        let sel = (selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sel.isEmpty {
            text += "\n\n```\n" + (sel.count > maxSelection ? String(sel.prefix(maxSelection)) + "\n…" : sel) + "\n```"
        }
        return CaptureAttachment(label: line.map { "\(name):\($0)" } ?? name, text: text)
    }

    /// The frontmost window: its app, title and (for a browser) URL.
    static func describeWindow(app: String, title: String, url: String?) -> CaptureAttachment? {
        let app = app.trimmingCharacters(in: .whitespaces)
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty || !title.isEmpty else { return nil }
        let label = !app.isEmpty && !title.isEmpty ? "\(app) — \(title)" : (app.isEmpty ? title : app)
        var text = !app.isEmpty && !title.isEmpty ? "\(app): \(title)" : (app.isEmpty ? title : app)
        if let url, !url.isEmpty { text += "\n\n\(url)" }
        return CaptureAttachment(label: label, text: text)
    }

    /// The context captured when the shortcut was pressed (a dropped file has nothing to put in the description).
    static func attachment(for context: PromptContext) -> CaptureAttachment? {
        switch context {
        case .code(let c): return describeCode(file: c.file, line: c.cursorLine, selection: c.selection)
        case .window(let app, let title, let url): return describeWindow(app: app, title: title, url: url)
        case .file: return nil
        }
    }

    /// "Make this a Linear issue" from a chat answer: its first line is the title, the whole answer the description.
    static func draft(fromAnswer answer: String) -> (line: String, description: String)? {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let first = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var line = first
            .replacingOccurrences(of: #"^(#{1,6}\s+|[-*+>]\s+|\d+[.)]\s+)+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if line.count > 120 { line = String(line.prefix(119)).trimmingCharacters(in: .whitespaces) + "…" }
        return (line, text)
    }
}

extension LinearAPI {
    static let teamsQuery = "query { viewer { id } teams(first: 100) { nodes { id key name } } }"
    static let issueCreateMutation =
        "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier title url branchName } } }"

    static func parseTeams(_ data: [String: Any]) -> (viewerID: String?, teams: [LinearTeam]) {
        let nodes = (data["teams"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let teams = nodes.compactMap { n -> LinearTeam? in
            guard let id = n["id"] as? String, let key = n["key"] as? String else { return nil }
            return LinearTeam(id: id, key: key, name: n["name"] as? String ?? key)
        }
        return ((data["viewer"] as? [String: Any])?["id"] as? String, teams)
    }

    /// The `input` of the mutation. Nil when the chip isn't ready, or "@me" has no viewer id.
    /// `description` (Markdown: the context the user chose to attach) is sent only when it has text.
    static func issueCreateInput(_ chip: PreviewChip, viewerID: String?, description: String? = nil) -> [String: Any]? {
        guard chip.ready, let team = chip.team else { return nil }
        var input: [String: Any] = ["teamId": team.id, "title": chip.title]
        if chip.priority > 0 { input["priority"] = chip.priority }
        if chip.assignToMe {
            guard let viewerID else { return nil }
            input["assigneeId"] = viewerID
        }
        if let due = chip.dueDate { input["dueDate"] = due }
        if let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            input["description"] = text
        }
        return input
    }

    /// Your teams and your user id (for "@me"). Read-only.
    static func teams() async throws -> (viewerID: String?, teams: [LinearTeam]) {
        parseTeams(try await query(teamsQuery))
    }

    /// Creates the issue. Call only after the user confirmed the preview (the second Enter / click).
    static func createIssue(_ chip: PreviewChip, viewerID: String?, description: String? = nil) async throws -> CreatedIssue {
        guard let input = issueCreateInput(chip, viewerID: viewerID, description: description) else {
            throw Failure.graphQL(L("The issue isn't ready to create"))
        }
        let data = try await query(issueCreateMutation, variables: ["input": input])
        guard let issue = CreatedIssue(data) else { throw Failure.graphQL(L("Linear didn't accept the issue")) }
        return issue
    }
}

// MARK: - Two-step flow

enum CaptureFlow {
    enum State: Equatable, Sendable {
        case editing(line: String)
        case preview(line: String, chip: PreviewChip)
        case creating(line: String, chip: PreviewChip)
        case done(line: String, issue: CreatedIssue)
        case failed(line: String, chip: PreviewChip, message: String)

        static let initial = State.editing(line: "")

        var line: String {
            switch self {
            case .editing(let l), .preview(let l, _), .creating(let l, _), .done(let l, _), .failed(let l, _, _): return l
            }
        }
    }

    enum Event: Sendable {
        case type(String)
        case enter                 // the Enter key or the Create button, the same thing
        case escape
        case created(CreatedIssue)
        case failed(String)
    }

    /// What the caller must do after a transition. Only `.create` touches Linear.
    enum Effect: Equatable, Sendable { case create(PreviewChip), close }

    struct Context: Sendable {
        var teams: [LinearTeam]
        var defaultTeamKey: String?
        var now: Date = .now
    }

    static func reduce(_ s: State, _ e: Event, _ ctx: Context) -> (state: State, effect: Effect?) {
        switch e {
        case .type(let line):
            // Typing never creates; any edit (even during a preview) goes back to editing.
            switch s {
            case .creating, .done: return (s, nil)
            default: return (.editing(line: line), nil)
            }
        case .escape:
            switch s {
            case .preview(let l, _), .failed(let l, _, _): return (.editing(line: l), nil)
            default: return (s, .close)
            }
        case .enter:
            switch s {
            case .editing(let line), .failed(let line, _, _):
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return (s, nil) }
                let chip = PreviewChip.make(QuickCapture.parse(line, now: ctx.now), teams: ctx.teams,
                                            defaultTeamKey: ctx.defaultTeamKey)
                return (.preview(line: line, chip: chip), nil)
            case .preview(let line, let chip):
                guard chip.ready else { return (s, nil) }   // problems are shown on the chip; nothing is sent
                return (.creating(line: line, chip: chip), .create(chip))
            case .done: return (s, .close)
            case .creating: return (s, nil)                 // a repeated Enter never sends twice
            }
        case .created(let issue):
            if case .creating(let line, _) = s { return (.done(line: line, issue: issue), nil) }
            return (s, nil)
        case .failed(let message):
            if case .creating(let line, let chip) = s { return (.failed(line: line, chip: chip, message: message), nil) }
            return (s, nil)
        }
    }
}
