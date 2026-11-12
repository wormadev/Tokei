import SwiftUI

/// Rows for the Menu bar section. The menu bar preview beside the form shows the result.
struct MenuBarSettings: View {
    let refresher: Refresher
    @AppStorage(Prefs.menuBarProviderKey) private var provider = ""
    @AppStorage(Prefs.menuBarFirstKey) private var first = "session"
    @AppStorage(Prefs.menuBarSecondKey) private var second = "weekly"
    @AppStorage(Prefs.menuBarStyleKey) private var style = MenuBarConfig.Style.rings.rawValue
    @AppStorage(Prefs.menuBarNumbersKey) private var numbers = MenuBarConfig.Numbers.first.rawValue
    @AppStorage(Prefs.menuBarLogoKey) private var logo = false

    private var labels: (first: String, second: String, firstOnly: String) {
        switch MenuBarConfig.Style(rawValue: style) ?? .rings {
        case .rings: ("Outer ring", "Inner ring", "Outer ring only")
        case .bars: ("Top bar", "Bottom bar", "Top bar only")
        case .none: ("First limit", "Second limit", "First limit only")
        }
    }

    /// Limits the shown provider reports, plus session and weekly, which every plan has.
    private var limits: [(id: String, label: String)] {
        _ = (provider, first, second)
        let shown = MenuBarIcon.make(states: refresher.states, enabled: refresher.enabled, config: .current, display: .current).provider
        let windows = shown.flatMap { refresher.states[$0]?.snapshot?.windows } ?? []
        var options: [(id: String, label: String)] = [("session", "Session"), ("weekly", "Weekly")]
        for window in windows where !options.contains(where: { $0.id == window.id }) {
            options.append((window.id, window.label))
        }
        for id in [first, second] where !id.isEmpty && !options.contains(where: { $0.id == id }) {
            options.append((id, MenuBarIcon.fallbackLabel(id)))
        }
        return options
    }

    var body: some View {
        Group {
            Picker("Provider", selection: $provider) {
                Text("First in list").tag("")
                Text("Highest usage").tag(MenuBarConfig.highestProvider)
                Text("Each, side by side").tag(MenuBarConfig.eachProvider)
                Divider()
                ForEach(ProviderID.allCases) { Text($0.name).tag($0.rawValue) }
            }
            Picker("Style", selection: $style) {
                ForEach(MenuBarConfig.Style.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Picker(labels.first, selection: $first) {
                ForEach(limits, id: \.id) { Text($0.label).tag($0.id) }
            }
            Picker(labels.second, selection: $second) {
                Text("None").tag("")
                Divider()
                ForEach(limits.filter { $0.id != first }, id: \.id) { Text($0.label).tag($0.id) }
            }
            Picker("Percentages", selection: $numbers) {
                Text("Hidden").tag(MenuBarConfig.Numbers.hidden.rawValue)
                Text(second.isEmpty ? "Shown" : labels.firstOnly).tag(MenuBarConfig.Numbers.first.rawValue)
                if !second.isEmpty {
                    Text("Both").tag(MenuBarConfig.Numbers.all.rawValue)
                }
            }
            // Shown anyway when the item can switch provider or there is one per provider.
            if ![MenuBarConfig.eachProvider, MenuBarConfig.highestProvider].contains(provider) {
                Toggle("Provider logo", isOn: $logo)
            }
            ShortcutRecorder()
        }
        .onChange(of: first) { _, new in
            if second == new { second = "" }
        }
        .onChange(of: second) { _, new in
            if new.isEmpty, numbers == MenuBarConfig.Numbers.all.rawValue { numbers = MenuBarConfig.Numbers.first.rawValue }
        }
    }
}
