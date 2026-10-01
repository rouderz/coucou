import AppKit
import Foundation
import SwiftUI

// MARK: - Model

/// One tool call in the current Claude Code turn (Read, Edit, Bash…).
struct ToolActivity: Identifiable, Equatable, Sendable {
    enum Status: Sendable { case running, done, failed }

    let id = UUID()
    let tool: String
    let detail: String?      // file name, command or query
    let toolUseID: String?
    var status: Status = .running

    /// Short English label shown in the steps column.
    var label: String {
        switch tool {
        case "Read":                     return "Read"
        case "Edit", "MultiEdit":        return "Edit"
        case "Write":                    return "Write"
        case "Bash":                     return "Bash"
        case "Grep", "Glob", "LS":       return "Search"
        case "WebSearch", "WebFetch":    return "Web"
        case "Task", "Agent":            return "Agent"
        case "TodoWrite":                return "Plan"
        case "Done":                     return "Done"
        default:                         return tool
        }
    }

    /// SF Symbol for the steps column.
    var icon: String {
        switch tool {
        case "Read":                     return "doc.text"
        case "Edit", "MultiEdit", "Write": return "pencil"
        case "Bash":                     return "terminal"
        case "Grep", "Glob", "LS":       return "magnifyingglass"
        case "WebSearch", "WebFetch":    return "globe"
        case "Task", "Agent":            return "person.2"
        case "TodoWrite":                return "checklist"
        case "Done":                     return "checkmark.seal"
        default:                         return "wrench.and.screwdriver"
        }
    }
}

/// A file change rendered as a small diff with real line numbers.
struct EditPreview: Identifiable, Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Sendable { case context, removed, added }
        let kind: Kind
        let number: Int?
        let text: String
    }

    let id = UUID()
    let file: String
    let relativePath: String
    let language: CodeLanguage
    let lines: [Line]
    let note: String?        // "new file", "+2 more edits"…

    var fileName: String { (file as NSString).lastPathComponent }
}

// MARK: - Building a preview from a hook's tool_input

enum EditPreviewBuilder {
    private static let context = 2
    private static let maxChanged = 200        // per side; the diff scrolls
    private static let maxFileBytes = 2_000_000

    /// Edit / MultiEdit / Write → preview; nil for other tools.
    static func build(tool: String, input: [String: Any], cwd: String) -> EditPreview? {
        guard let file = input["file_path"] as? String, !file.isEmpty else { return nil }
        let rel = relative(file, to: cwd)
        let lang = CodeLanguage(path: file)

        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String else { return nil }
            return edit(file: file, rel: rel, lang: lang, old: old, new: new, note: nil)

        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]], let first = edits.first,
                  let old = first["old_string"] as? String,
                  let new = first["new_string"] as? String else { return nil }
            let more = edits.count > 1 ? "+\(edits.count - 1) more edit\(edits.count > 2 ? "s" : "")" : nil
            return edit(file: file, rel: rel, lang: lang, old: old, new: new, note: more)

        case "Write":
            let content = input["content"] as? String ?? ""
            let exists = FileManager.default.fileExists(atPath: file)
            let all = content.components(separatedBy: "\n")
            let lines = all.prefix(400).enumerated().map {
                EditPreview.Line(kind: .added, number: $0.offset + 1, text: $0.element)
            }
            let extra = " · \(all.count) line\(all.count == 1 ? "" : "s")"
            return EditPreview(file: file, relativePath: rel, language: lang, lines: Array(lines),
                               note: (exists ? "rewrite" : "new file") + extra)

        default:
            return nil
        }
    }

    private static func edit(file: String, rel: String, lang: CodeLanguage,
                             old: String, new: String, note: String?) -> EditPreview {
        var oldLines = old.components(separatedBy: "\n")
        var newLines = new.components(separatedBy: "\n")

        // Where the change starts in the file on disk (not yet modified at PreToolUse).
        var fileLines: [String] = []
        var startLine: Int?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file),
           (attrs[.size] as? Int ?? 0) <= maxFileBytes,
           let text = try? String(contentsOfFile: file, encoding: .utf8) {
            fileLines = text.components(separatedBy: "\n")
            if let range = text.range(of: old) {
                startLine = text[..<range.lowerBound].reduce(0) { $1 == "\n" ? $0 + 1 : $0 } + 1
            }
        }

        // Lines identical at both ends aren't part of the change: show them as context.
        var leading = 0
        while leading < oldLines.count - 1, leading < newLines.count - 1, oldLines[leading] == newLines[leading] {
            leading += 1
        }
        var trailing = 0
        while trailing < oldLines.count - leading - 1, trailing < newLines.count - leading - 1,
              oldLines[oldLines.count - 1 - trailing] == newLines[newLines.count - 1 - trailing] {
            trailing += 1
        }
        let sameHead = Array(oldLines.prefix(leading))
        let sameTail = Array(oldLines.suffix(trailing))
        oldLines = Array(oldLines.dropFirst(leading).dropLast(trailing))
        newLines = Array(newLines.dropFirst(leading).dropLast(trailing))

        var lines: [EditPreview.Line] = []
        let changeStart = startLine.map { $0 + leading }

        // Context above: from the file, else from the edit's own unchanged head.
        if let changeStart, !fileLines.isEmpty {
            let from = max(1, changeStart - context)
            for n in from..<changeStart where n - 1 < fileLines.count {
                lines.append(.init(kind: .context, number: n, text: fileLines[n - 1]))
            }
        } else {
            for (i, t) in sameHead.suffix(context).enumerated() {
                lines.append(.init(kind: .context, number: nil, text: t))
                _ = i
            }
        }

        for (i, t) in oldLines.prefix(maxChanged).enumerated() {
            lines.append(.init(kind: .removed, number: changeStart.map { $0 + i }, text: t))
        }
        for (i, t) in newLines.prefix(maxChanged).enumerated() {
            lines.append(.init(kind: .added, number: changeStart.map { $0 + i }, text: t))
        }

        // Context below, numbered as in the new file.
        if let changeStart, !fileLines.isEmpty {
            let afterOld = changeStart + oldLines.count       // first unchanged line in the old file
            let shift = newLines.count - oldLines.count
            for n in afterOld..<(afterOld + context) where n - 1 < fileLines.count && n >= 1 {
                lines.append(.init(kind: .context, number: n + shift, text: fileLines[n - 1]))
            }
        } else {
            for t in sameTail.prefix(context) {
                lines.append(.init(kind: .context, number: nil, text: t))
            }
        }

        let truncated = oldLines.count > maxChanged || newLines.count > maxChanged
        let notes = [note, truncated ? "diff truncated" : nil].compactMap { $0 }
        return EditPreview(file: file, relativePath: rel, language: lang, lines: lines,
                           note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    private static func relative(_ file: String, to cwd: String) -> String {
        guard !cwd.isEmpty, file.hasPrefix(cwd + "/") else { return (file as NSString).lastPathComponent }
        return String(file.dropFirst(cwd.count + 1))
    }
}

// MARK: - Languages and syntax highlighting

enum CodeLanguage: Equatable, Sendable {
    case typescript, javascript, swift, python, go, rust, json, markdown, other

    init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "ts", "tsx", "mts", "cts":      self = .typescript
        case "js", "jsx", "mjs", "cjs":      self = .javascript
        case "swift":                        self = .swift
        case "py":                           self = .python
        case "go":                           self = .go
        case "rs":                           self = .rust
        case "json":                         self = .json
        case "md", "mdx":                    self = .markdown
        default:                             self = .other
        }
    }

    /// Two-letter badge and its colour for the file tab.
    var badge: (text: String, color: String) {
        switch self {
        case .typescript: return ("TS", "#3178C6")
        case .javascript: return ("JS", "#B8A419")
        case .swift:      return ("SW", "#F05138")
        case .python:     return ("PY", "#3776AB")
        case .go:         return ("GO", "#00ADD8")
        case .rust:       return ("RS", "#B7410E")
        case .json:       return ("{}", "#6B7079")
        case .markdown:   return ("MD", "#6B7079")
        case .other:      return ("··", "#4B5563")
        }
    }

    fileprivate var keywords: Set<String> {
        switch self {
        case .typescript, .javascript:
            return ["import", "from", "export", "default", "const", "let", "var", "function", "return",
                    "if", "else", "for", "while", "of", "in", "new", "class", "extends", "interface",
                    "type", "async", "await", "try", "catch", "throw", "switch", "case", "break",
                    "true", "false", "null", "undefined", "this", "typeof", "as", "implements"]
        case .swift:
            return ["import", "let", "var", "func", "return", "if", "else", "guard", "for", "in",
                    "while", "struct", "class", "enum", "protocol", "extension", "case", "switch",
                    "private", "fileprivate", "public", "static", "self", "Self", "true", "false",
                    "nil", "try", "await", "async", "throws", "init", "some", "any", "where", "defer"]
        case .python:
            return ["import", "from", "def", "return", "if", "elif", "else", "for", "in", "while",
                    "class", "with", "as", "try", "except", "raise", "lambda", "None", "True",
                    "False", "and", "or", "not", "async", "await", "yield", "pass", "self"]
        case .go:
            return ["package", "import", "func", "return", "if", "else", "for", "range", "var",
                    "const", "type", "struct", "interface", "map", "chan", "go", "defer", "nil",
                    "true", "false", "switch", "case", "err"]
        case .rust:
            return ["use", "fn", "let", "mut", "return", "if", "else", "for", "in", "while", "loop",
                    "struct", "enum", "impl", "trait", "pub", "match", "self", "Self", "true",
                    "false", "async", "await", "mod", "crate", "where"]
        case .json, .markdown, .other:
            return ["true", "false", "null"]
        }
    }

    fileprivate var lineComment: String? {
        switch self {
        case .python: return "#"
        case .json, .markdown, .other: return nil
        default: return "//"
        }
    }
}

@MainActor
enum SyntaxHighlighter {
    static let plain    = Color(hex: "#E6E8EB")
    static let keyword  = Color(hex: "#C792EA")
    static let string   = Color(hex: "#C3E88D")
    static let number   = Color(hex: "#F78C6C")
    static let comment  = Color(hex: "#5C6370")
    static let typeName = Color(hex: "#FFCB6B")
    static let function = Color(hex: "#82AAFF")

    /// Colours one line with a small tokenizer: keywords, strings, numbers, comments,
    /// type names (Capitalised) and function calls. Good enough for a glance, no dependencies.
    static func highlight(_ line: String, _ lang: CodeLanguage) -> AttributedString {
        var out = AttributedString()
        func add(_ s: Substring, _ c: Color) {
            var a = AttributedString(String(s)); a.foregroundColor = c; out.append(a)
        }
        let chars = Array(line)
        var i = 0
        let kw = lang.keywords

        while i < chars.count {
            let c = chars[i]
            // Line comment
            if let lc = lang.lineComment, line[line.index(line.startIndex, offsetBy: i)...].hasPrefix(lc) {
                add(Substring(String(chars[i...])), comment); break
            }
            // Strings
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                add(Substring(String(chars[i..<j])), string); i = j; continue
            }
            // Numbers
            if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "_" { j += 1 }
                add(Substring(String(chars[i..<j])), number); i = j; continue
            }
            // Identifiers
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" { j += 1 }
                let word = String(chars[i..<j])
                let color: Color
                if kw.contains(word) { color = keyword }
                else if j < chars.count, chars[j] == "(" { color = function }
                else if word.first?.isUppercase == true { color = typeName }
                else { color = plain }
                add(Substring(word), color); i = j; continue
            }
            add(Substring(String(c)), plain); i += 1
        }
        return out
    }
}


// MARK: - View

/// Live view of the current Claude Code turn: the file being changed as a diff,
/// and the steps so far. Doubles as the approval screen for file edits.
struct LiveSessionView: View {
    @ObservedObject var state: AppState

    private var steps: [ToolActivity] { Array(state.liveActivities.suffix(3)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground<EmptyView>(wash: state.pendingApproval != nil ? CardBackground<EmptyView>.Wash.amber : nil)
            HStack(alignment: .top, spacing: 14) {
                // Left: Mochi (drawn by BotPlacement above this spacer), project, steps
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 88)
                    Text(state.liveProject ?? "Session")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1)
                    Text("Claude Code")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#8E939C"))
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(steps) { StepRow(activity: $0) }
                    }
                    .padding(.top, 10)
                }
                .frame(width: 128, alignment: .leading)

                CodePanel(state: state)
            }
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .padding(.vertical, 12)
        }
        .clipped()  // never spill over the island header
    }
}

private struct StepRow: View {
    let activity: ToolActivity

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch activity.status {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Color(hex: "#22C55E"))
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundColor(Color(hex: "#F4505E"))
                case .running:
                    ProgressView().controlSize(.mini).tint(Color(hex: "#F5F6F8"))
                }
            }
            .font(.system(size: 13))
            .frame(width: 16, height: 16)
            Text(activity.label)
                .font(.system(size: 13, weight: activity.status == .running ? .semibold : .regular))
                .foregroundColor(Color(hex: activity.status == .running ? "#F5F6F8" : "#8E939C"))
                .lineLimit(1)
        }
        .help(activity.detail ?? activity.label)
    }
}

private struct CodePanel: View {
    @ObservedObject var state: AppState
    @State private var reveal: Double = 1

    private let mono = Font.system(size: 11.5, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let edit = state.liveEdit {
                header(edit)
                // Scrolls inside the panel: a long change never stretches the island.
                ScrollView(.vertical, showsIndicators: true) { diff(edit) }
                    .frame(maxHeight: .infinity)
                    .task(id: edit.id) {
                        // Typing reveal of the added lines (cosmetic, ~0.6 s), short changes only.
                        guard edit.lines.count <= 30 else { reveal = 1; return }
                        reveal = 0
                        for step in 1...24 {
                            try? await Task.sleep(for: .milliseconds(25))
                            reveal = Double(step) / 24
                        }
                    }
            } else {
                idle
            }
            Spacer(minLength: 0)
            if state.pendingApproval != nil { approvalBar } else { actionBar }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: "#0E0F12"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func header(_ edit: EditPreview) -> some View {
        HStack(spacing: 7) {
            Text(edit.language.badge.text)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 18, height: 14)
                .background(Color(hex: edit.language.badge.color))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(edit.fileName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "#E6E8EB"))
                .lineLimit(1)
            if state.liveActivities.last?.status == .running {
                Circle().fill(Color(hex: "#F5A524")).frame(width: 5, height: 5)
            }
            if let note = edit.note {
                Text(note).font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(edit.relativePath)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(hex: "#6B7079"))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
    }

    private func diff(_ edit: EditPreview) -> some View {
        let lastAdded = edit.lines.lastIndex { $0.kind == .added }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(edit.lines.enumerated()), id: \.offset) { idx, line in
                row(line, lang: edit.language, caret: idx == lastAdded && reveal < 1)
            }
        }
        .padding(.vertical, 6)
    }

    private func row(_ line: EditPreview.Line, lang: CodeLanguage, caret: Bool) -> some View {
        let (marker, bar, bg): (String, Color, Color) = switch line.kind {
        case .removed: ("-", Color(hex: "#F4505E"), Color(hex: "#F4505E").opacity(0.13))
        case .added:   ("+", Color(hex: "#22C55E"), Color(hex: "#22C55E").opacity(0.12))
        case .context: (" ", .clear, .clear)
        }
        var text: AttributedString
        if line.kind == .added && reveal < 1 {
            let shown = Int(Double(line.text.count) * reveal)
            text = SyntaxHighlighter.highlight(String(line.text.prefix(shown)), lang)
        } else {
            text = SyntaxHighlighter.highlight(line.text, lang)
        }
        if line.kind == .removed {
            text.strikethroughStyle = .single
            text.foregroundColor = Color(hex: "#F4505E").opacity(0.75)
        }
        return HStack(spacing: 0) {
            Rectangle().fill(bar).frame(width: 2)
            Text(line.number.map(String.init) ?? "")
                .font(mono)
                .foregroundColor(Color(hex: line.kind == .context ? "#4B5563" : (line.kind == .added ? "#22C55E" : "#F4505E")))
                .frame(width: 30, alignment: .trailing)
            Text(marker)
                .font(mono)
                .foregroundColor(bar)
                .frame(width: 18)
            Text(text).font(mono).lineLimit(1).truncationMode(.tail)
            if caret {
                Rectangle().fill(Color(hex: "#E6E8EB")).frame(width: 1.5, height: 13)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .background(bg)
    }

    @ViewBuilder private var idle: some View {
        let last = state.liveActivities.last
        VStack(alignment: .leading, spacing: 6) {
            if let last, last.tool == "Bash", let cmd = last.detail {
                Text("$ " + cmd)
                    .font(mono)
                    .foregroundColor(Color(hex: "#E6E8EB"))
                    .lineLimit(4)
            } else if let last, last.status == .running {
                Text("\(last.label)\(last.detail.map { " · \($0)" } ?? "")…")
                    .font(mono)
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(2)
            } else {
                Text("Waiting for Claude…")
                    .font(mono)
                    .foregroundColor(Color(hex: "#6B7079"))
            }
        }
        .padding(12)
    }

    private var finished: Bool { state.liveActivities.last?.tool == "Done" }

    /// Status + what you can do with the change: ask about it, open it, or go back.
    private var actionBar: some View {
        HStack(spacing: 6) {
            if finished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#22C55E"))
                Text("Done · \(state.liveActivities.count - 1) step\(state.liveActivities.count == 2 ? "" : "s")")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
            } else {
                ProgressView().controlSize(.mini)
                Text("Working…").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
            }
            Spacer()
            if let edit = state.liveEdit {
                ChipButton("Ask Mochi", icon: "bubble.left") { askMochi(about: edit) }
                    .help("Ask about this change in the chat")
                ChipButton("Open", icon: "pencil") {
                    if let editor = Editor.preferred(state.preferredEditor) {
                        editor.open(folder: edit.file)
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: edit.file))
                    }
                }
                .help("Open the file in your editor")
            }
            ChipButton("Back", icon: "chevron.left") {
                state.view = state.tasks.isEmpty ? .empty : .overview
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
    }

    /// Opens a fresh chat with the file and this change attached (read-only assistant).
    private func askMochi(about edit: EditPreview) {
        let session = state.tasks.first { $0.id == "integration_claude" }?.sessionCwd
        let change = edit.lines.filter { $0.kind != .context }
            .map { ($0.kind == .removed ? "- " : "+ ") + $0.text }
            .joined(separator: "\n")
        let context = CodeContext(
            appName: "Claude Code",
            file: edit.file,
            project: CodeContextCapture.projectRoot(for: edit.file, sessionFolder: session),
            selection: "Change Claude Code just made (- removed, + added):\n" + change)
        ChatSession.startNew(state)
        state.promptContext = .code(context)
        state.view = .prompt
    }

    private var approvalBar: some View {
        HStack(spacing: 8) {
            Text("Claude wants to make this change")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#F5A524"))
            Spacer()
            SecondaryButton("Deny")   { HookServer.shared.sendApprovalDecision("deny") }
            PrimaryButton("Allow")    { HookServer.shared.sendApprovalDecision("allow") }
            SecondaryButton("Always") { HookServer.shared.sendApprovalDecision("always") }
        }
        .padding(8)
        .background(Color.white.opacity(0.03))
    }
}


/// Small capsule button used in the live view's action bar.
private struct ChipButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Color(hex: "#C5C8CD"))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
