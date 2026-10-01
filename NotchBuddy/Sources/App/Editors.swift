import AppKit

/// Code editors / IDEs Coucou can open a Claude Code project in.
struct Editor: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Bundle IDs, most common first (stable, insiders / community editions…).
    let bundleIDs: [String]

    static let catalog: [Editor] = [
        Editor(id: "vscode",       name: "VS Code",          bundleIDs: ["com.microsoft.VSCode"]),
        Editor(id: "cursor",       name: "Cursor",           bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        Editor(id: "windsurf",     name: "Windsurf",         bundleIDs: ["com.exafunction.windsurf"]),
        Editor(id: "zed",          name: "Zed",              bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        Editor(id: "vscode-insiders", name: "VS Code Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"]),
        Editor(id: "vscodium",     name: "VSCodium",         bundleIDs: ["com.vscodium", "com.vscodium.codium"]),
        Editor(id: "intellij",     name: "IntelliJ IDEA",    bundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        Editor(id: "webstorm",     name: "WebStorm",         bundleIDs: ["com.jetbrains.WebStorm"]),
        Editor(id: "pycharm",      name: "PyCharm",          bundleIDs: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        Editor(id: "goland",       name: "GoLand",           bundleIDs: ["com.jetbrains.goland"]),
        Editor(id: "rustrover",    name: "RustRover",        bundleIDs: ["com.jetbrains.rustrover"]),
        Editor(id: "android-studio", name: "Android Studio", bundleIDs: ["com.google.android.studio"]),
        Editor(id: "xcode",        name: "Xcode",            bundleIDs: ["com.apple.dt.Xcode"]),
        Editor(id: "sublime",      name: "Sublime Text",     bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"]),
        Editor(id: "nova",         name: "Nova",             bundleIDs: ["com.panic.Nova"]),
    ]

    /// The installed app for this editor, if any.
    @MainActor
    var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Editors from the catalog that are installed on this Mac, in catalog order.
    @MainActor
    static var installed: [Editor] { catalog.filter { $0.appURL != nil } }

    /// The user's choice if it's still installed, otherwise the first installed editor.
    @MainActor
    static func preferred(_ id: String?) -> Editor? {
        let installed = installed
        return installed.first { $0.id == id } ?? installed.first
    }

    /// Opens `folder` in this editor, or just brings the editor forward when there's none.
    @MainActor
    func open(folder: String?) {
        if let running = bundleIDs.lazy.compactMap({ id in
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
        }).first, folder == nil || folder?.isEmpty == true {
            running.activate()
            return
        }
        guard let appURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let folder, !folder.isEmpty {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: appURL,
                                    configuration: config, completionHandler: nil)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }
}
