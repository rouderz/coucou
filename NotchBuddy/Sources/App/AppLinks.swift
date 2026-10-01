import AppKit

/// Opens web links in the service's own Mac app when it's installed (Linear, Notion…),
/// otherwise in the browser. Both apps accept their web URLs with their own scheme.
enum AppLinks {
    private struct NativeApp {
        let hosts: [String]          // web hosts the app handles
        let bundleIDs: [String]
        let scheme: String           // "linear" → linear://linear.app/…
    }

    private static let apps: [NativeApp] = [
        NativeApp(hosts: ["linear.app"], bundleIDs: ["com.linear"], scheme: "linear"),
        NativeApp(hosts: ["notion.so", "www.notion.so", "notion.site"], bundleIDs: ["notion.id"], scheme: "notion"),
    ]

    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(appURL(for: url) ?? url)
    }

    @MainActor
    static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        open(url)
    }

    /// The same link with the app's scheme, if the app is installed.
    @MainActor
    static func appURL(for url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              let app = apps.first(where: { app in app.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }),
              app.bundleIDs.contains(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = app.scheme
        return parts.url
    }
}
