import AppKit

/// Localized text from Localizable.xcstrings. The key is the English text (with %@ / %lld for
/// interpolations), so untranslated strings still show in English.
func L(_ key: String.LocalizationValue) -> String { String(localized: key) }

/// Interface language (#48): follows the Mac unless the user picks one in Settings.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, es
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Same as the Mac")
        case .en: return "English"
        case .es: return "Español"
        }
    }

    /// The language this run of the app started with (a change needs a restart).
    static let atLaunch = AppLanguage.current

    static var current: AppLanguage {
        guard let list = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              UserDefaults.standard.object(forKey: "coucouLanguage") != nil,
              let first = list.first else { return .system }
        return first.hasPrefix("es") ? .es : .en
    }

    /// Saved for the next launch (macOS reads AppleLanguages when the app starts).
    func apply() {
        let ud = UserDefaults.standard
        if self == .system {
            ud.removeObject(forKey: "AppleLanguages")
            ud.removeObject(forKey: "coucouLanguage")
        } else {
            ud.set([rawValue], forKey: "AppleLanguages")
            ud.set(rawValue, forKey: "coucouLanguage")
        }
    }

    /// Relaunches Coucou so the new language takes effect.
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
