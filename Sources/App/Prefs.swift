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
    static let providerOrderKey = "providerOrder"

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

    /// Panel order. Stored as "claude,codex,…"; providers missing from it are appended.
    static var providerOrder: [ProviderID] {
        get {
            let saved = (UserDefaults.standard.string(forKey: providerOrderKey) ?? "")
                .split(separator: ",").compactMap { ProviderID(rawValue: String($0)) }
            return saved + ProviderID.allCases.filter { !saved.contains($0) }
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).joined(separator: ","), forKey: providerOrderKey) }
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

/// Stored as "icon", "highest" or a provider's raw value.
enum MenuBarStyle: Hashable, Identifiable {
    case icon, highest, provider(ProviderID)

    static var all: [MenuBarStyle] { [.icon, .highest] + ProviderID.allCases.map { .provider($0) } }

    init(rawValue: String?) {
        switch rawValue {
        case "icon": self = .icon
        case let raw?: self = ProviderID(rawValue: raw).map { .provider($0) } ?? .highest
        case nil: self = .highest
        }
    }

    var rawValue: String {
        switch self {
        case .icon: "icon"
        case .highest: "highest"
        case let .provider(id): id.rawValue
        }
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .icon: "Icon only"
        case .highest: "Highest usage"
        case let .provider(id): "\(id.name) usage"
        }
    }

    /// Providers whose usage feeds the menu bar number; nil means no number.
    func sources(enabled: [ProviderID]) -> [ProviderID]? {
        switch self {
        case .icon: nil
        case .highest: enabled
        case let .provider(id): [id]
        }
    }
}
