import Foundation

/// UserDefaults keys. Views bind with @AppStorage(Prefs.key); non-view code reads the statics.
enum Prefs {
    static let refreshIntervalKey = "refreshInterval"
    static let menuBarStyleKey = "menuBarStyle"
    static let showAccountKey = "show.account"
    static let showDetailsKey = "show.details"
    static let showModelLimitsKey = "show.modelLimits"
    static let showHistoryKey = "show.history"
    static let absoluteResetsKey = "show.absoluteResets"
    static let didDetectKey = "didDetectProviders"

    static func enabledKey(_ id: ProviderID) -> String { "enabled.\(id.rawValue)" }

    static func registerDefaults() {
        var defaults: [String: Any] = [
            refreshIntervalKey: 300,
            menuBarStyleKey: MenuBarStyle.highest.rawValue,
            showAccountKey: true,
            showDetailsKey: false,
            showModelLimitsKey: false,
            showHistoryKey: false,
            absoluteResetsKey: false,
        ]
        for id in ProviderID.allCases { defaults[enabledKey(id)] = true }
        UserDefaults.standard.register(defaults: defaults)
    }

    static var refreshInterval: TimeInterval {
        TimeInterval(max(60, UserDefaults.standard.integer(forKey: refreshIntervalKey)))
    }

    static func isEnabled(_ id: ProviderID) -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey(id))
    }

    /// First launch: enable only providers whose credentials exist, so the panel isn't a wall of
    /// "not set up" rows. Presence checks only; nothing here reads a secret or prompts.
    static func detectProvidersOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didDetectKey) else { return }
        let fm = FileManager.default
        let found: [ProviderID: Bool] = [
            .claude: fm.fileExists(atPath: ClaudeProvider.credentialsFile.path) || Keychain.exists(service: ClaudeProvider.keychainService),
            .codex: fm.fileExists(atPath: CodexProvider.authFile.path),
            .cursor: fm.fileExists(atPath: CursorProvider.stateDB.path),
            .gemini: fm.fileExists(atPath: GeminiProvider.credsFile.path),
            .copilot: false,
        ]
        for (id, present) in found { defaults.set(present, forKey: enabledKey(id)) }
        defaults.set(true, forKey: didDetectKey)
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, highest
    var id: String { rawValue }

    var label: String {
        switch self {
        case .icon: "Icon only"
        case .highest: "Icon and highest usage"
        }
    }
}
