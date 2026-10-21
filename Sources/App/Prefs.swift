import Foundation

/// UserDefaults keys. Views bind with @AppStorage(Prefs.key); non-view code reads the statics.
enum Prefs {
    static let refreshIntervalKey = "refreshInterval"
    static let usageDisplayKey = "usageDisplay"
    static let menuBarWeeklyKey = "menuBar.weekly"
    static let menuBarSessionKey = "menuBar.session"
    static let showAccountKey = "show.account"
    static let showDetailsKey = "show.details"
    static let showModelLimitsKey = "show.modelLimits"
    static let showHistoryKey = "show.history"
    static let absoluteResetsKey = "show.absoluteResets"
    static let providerOrderKey = "providerOrder"
    static let refreshOnOpenKey = "refreshOnOpen"

    static func enabledKey(_ id: ProviderID) -> String { "enabled.\(id.rawValue)" }

    static func registerDefaults() {
        var defaults: [String: Any] = [
            refreshIntervalKey: 300,
            refreshOnOpenKey: true,
            usageDisplayKey: UsageDisplay.used.rawValue,
            menuBarWeeklyKey: false,
            menuBarSessionKey: true,
            showAccountKey: true,
            showDetailsKey: false,
            showModelLimitsKey: false,
            showHistoryKey: false,
            absoluteResetsKey: false,
        ]
        for id in ProviderID.allCases { defaults[enabledKey(id)] = true }
        UserDefaults.standard.register(defaults: defaults)
    }

    /// Seconds between background refreshes; nil for "Only when opened" (stored as -1).
    static var refreshInterval: TimeInterval? {
        let raw = UserDefaults.standard.integer(forKey: refreshIntervalKey)
        if raw < 0 { return nil }
        return raw == 0 ? 300 : TimeInterval(max(60, raw))
    }

    static var refreshOnOpen: Bool {
        UserDefaults.standard.object(forKey: refreshOnOpenKey) as? Bool ?? true
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
}

/// Show usage as consumed or as what's left. Bars, rings and numbers all follow it.
enum UsageDisplay: String, CaseIterable, Identifiable {
    case used, remaining
    var id: String { rawValue }

    static var current: UsageDisplay {
        UsageDisplay(rawValue: UserDefaults.standard.string(forKey: Prefs.usageDisplayKey) ?? "") ?? .used
    }

    var label: String {
        switch self {
        case .used: "As used"
        case .remaining: "Remaining"
        }
    }

    func value(_ used: Double) -> Double {
        switch self {
        case .used: used
        case .remaining: max(0, 1 - used)
        }
    }

    func text(_ used: Double) -> String {
        "\(Int((value(used) * 100).rounded()))%"
    }
}
