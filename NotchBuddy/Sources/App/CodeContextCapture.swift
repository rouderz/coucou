import AppKit
import ApplicationServices

/// What the user is working on in their editor: the file, its project and the selection.
struct CodeContext: Equatable, Sendable {
    let appName: String
    /// Absolute path of the file in the focused editor window.
    let file: String
    /// Project root (nearest folder with `.git`, else the Claude Code session folder,
    /// else the file's folder). The assistant chat runs here, read-only.
    let project: String
    /// Selected text, when the editor exposes it (trimmed to a sane size).
    let selection: String?

    var fileName: String { (file as NSString).lastPathComponent }
    var projectName: String { (project as NSString).lastPathComponent }

    /// What the model is told about the code context.
    var promptPreamble: String {
        var text = """
        The user is working in \(appName) on the file `\(relativePath)` of the project `\(projectName)` \
        (your working directory is the project root). Read that file, and any related files you need, \
        before answering. You can read and search the project but you cannot modify anything: \
        suggest changes as code in your answer.
        """
        if let selection {
            text += "\n\nThe user selected this text in the file:\n```\n\(selection)\n```"
        }
        return text + "\n\n"
    }

    /// Same, for the API-key engine, where the file is attached inline instead.
    var inlinePreamble: String {
        var text = "The user is working in \(appName) on `\(relativePath)` (project `\(projectName)`); " +
                   "its contents are attached above. Suggest changes as code in your answer."
        if let selection {
            text += "\n\nThe user selected this text in the file:\n```\n\(selection)\n```"
        }
        return text + "\n\n"
    }

    /// File path relative to the project, for prompts and the context chip.
    var relativePath: String {
        file.hasPrefix(project + "/") ? String(file.dropFirst(project.count + 1)) : fileName
    }
}

/// Reads the focused editor window through Accessibility to find the open file.
enum CodeContextCapture {
    private static let maxSelection = 8_000  // characters

    /// Returns the code context for `app`, or nil when its focused window isn't a file.
    @MainActor
    static func capture(from app: NSRunningApplication?) -> CodeContext? {
        #if APPSTORE
        return nil
        #else
        guard let app, let appName = app.localizedName else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        let axStatus = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard axStatus == .success, let windowRef else {
            assistantLog.info("capture: no focused window (AX error \(axStatus.rawValue))")
            return nil
        }
        let window = windowRef as! AXUIElement  // CF type, the cast can't fail

        let sessionFolder = AppState.shared.tasks
            .first { $0.id == "integration_claude" }?.sessionCwd

        // 1. The window's document (native apps, and editors that set it).
        var file = documentPath(of: window)
        assistantLog.info("capture: AXDocument=\(file ?? "nil", privacy: .public) title=\(string(window, kAXTitleAttribute) ?? "nil", privacy: .public)")

        // 2. Fallback: the file name from the title, looked up in the project folder.
        if file == nil, isEditor(app), let title = string(window, kAXTitleAttribute),
           let name = fileName(fromTitle: title) {
            let roots = [sessionFolder].compactMap { $0 }
            file = roots.lazy.compactMap { find(name, under: $0) }.first
        }
        guard let file else { return nil }

        return CodeContext(appName: appName,
                           file: file,
                           project: projectRoot(for: file, sessionFolder: sessionFolder),
                           selection: selectedText(in: axApp))
        #endif
    }

    // MARK: - Accessibility helpers

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// `AXDocument` is a file URL string ("file:///Users/…/main.swift").
    private static func documentPath(of window: AXUIElement) -> String? {
        guard let raw = string(window, kAXDocumentAttribute), !raw.isEmpty else { return nil }
        let path = URL(string: raw)?.isFileURL == true ? URL(string: raw)!.path : raw
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return path
    }

    private static func selectedText(in axApp: AXUIElement) -> String? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement
        guard let text = string(focused, kAXSelectedTextAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > maxSelection ? String(text.prefix(maxSelection)) + "\n…" : text
    }

    // MARK: - Title fallback

    private static func isEditor(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return Editor.catalog.contains { $0.bundleIDs.contains(id) }
    }

    /// "● cart.ts — shopit" / "cart.ts - shopit - Visual Studio Code" → "cart.ts"
    static func fileName(fromTitle title: String) -> String? {
        var first = title
        for separator in [" — ", " – ", " - "] {
            if let range = first.range(of: separator) { first = String(first[..<range.lowerBound]) }
        }
        first = first.trimmingCharacters(in: CharacterSet(charactersIn: "●•* ").union(.whitespaces))
        guard first.contains("."), !first.contains("/"), first.count < 200 else { return nil }
        return first
    }

    /// Breadth-first search for a file name, skipping dependency and build folders.
    private static func find(_ name: String, under root: String, limit: Int = 20_000) -> String? {
        let skip: Set<String> = ["node_modules", ".git", "build", "dist", "DerivedData", ".next",
                                 "Pods", ".build", "target", "vendor", ".venv", "venv", "__pycache__"]
        let rootURL = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return nil }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit { break }
            if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if url.lastPathComponent == name { return url.path }
        }
        return nil
    }

    // MARK: - Project root

    static func projectRoot(for file: String, sessionFolder: String?) -> String {
        let fm = FileManager.default
        var dir = (file as NSString).deletingLastPathComponent
        let home = fm.homeDirectoryForCurrentUser.path
        while dir.count > 1 && dir != home {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if let sessionFolder, file.hasPrefix(sessionFolder + "/") { return sessionFolder }
        return (file as NSString).deletingLastPathComponent
    }
}
