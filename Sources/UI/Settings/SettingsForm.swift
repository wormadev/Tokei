import SwiftUI

/// The left column. What changes the panel or menu bar sits open; the rest folds away.
struct SettingsForm: View {
    let refresher: Refresher

    @AppStorage(Prefs.providerOrderKey) private var orderRaw = ""
    @AppStorage(Prefs.menuBarIconKey) private var menuBarIcon = MenuBarIcon.tokei
    @AppStorage(Prefs.menuBarSessionKey) private var menuBarSession = true
    @AppStorage(Prefs.menuBarWeeklyKey) private var menuBarWeekly = false
    @AppStorage(Prefs.usageDisplayKey) private var usageDisplay = UsageDisplay.used.rawValue
    @AppStorage(Prefs.absoluteResetsKey) private var absoluteResets = false
    @AppStorage(Prefs.showPaceKey) private var showPace = true
    @AppStorage(Prefs.showAccountKey) private var showAccount = true
    @AppStorage(Prefs.showStatusKey) private var showStatus = true
    @AppStorage(Prefs.showDetailsKey) private var showDetails = false
    @AppStorage(Prefs.showModelLimitsKey) private var showModelLimits = true
    @AppStorage(Prefs.showHistoryKey) private var showHistory = false

    private var order: [ProviderID] {
        let _ = orderRaw
        return Prefs.providerOrder
    }

    private var snapshots: [Snapshot] {
        refresher.enabled.compactMap { refresher.states[$0]?.snapshot }
    }

    private var historyReady: Bool {
        refresher.enabled.contains { id in refresher.history.series.contains { $0.key.hasPrefix("\(id.rawValue)/") && $0.value.count > 1 } }
    }

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(order) { ProviderRow(id: $0, refresher: refresher) }
                if let last = order.last, order.count > 1 {
                    Button {
                        Prefs.providerOrder = [last] + order.dropLast()
                    } label: {
                        Label("Show \(last.name) first", systemImage: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("The first provider leads the panel and drives the menu bar")
                }
            }
            Section("Menu bar") {
                Picker("Icon", selection: $menuBarIcon) {
                    ForEach(MenuBarIcon.allCases) { Text($0.label).tag($0) }
                }
                Toggle("5-hour session number", isOn: $menuBarSession)
                Toggle("Weekly number", isOn: $menuBarWeekly)
            }
            Section("Panel") {
                Picker("Usage", selection: $usageDisplay) {
                    ForEach(UsageDisplay.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Resets", selection: $absoluteResets) {
                    Text("Countdown").tag(false)
                    Text("Clock time").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Pace", isOn: $showPace)
                    .help("Ahead or behind an even spread over the window, and whether it lasts until reset")
                Toggle("Account and plan", isOn: $showAccount)
                Toggle("Service status", isOn: $showStatus)
                    .help("Outages of Claude Code or Codex from status.claude.com and status.openai.com")
                toggle("Spend and credits", isOn: $showDetails, available: snapshots.contains { !$0.details.isEmpty },
                       note: "None of your providers report spend or credits right now.")
                toggle("Per-model limits", isOn: $showModelLimits, available: snapshots.contains { $0.windows.contains { $0.kind == .secondary } },
                       note: "None of your providers report per-model limits right now.")
                toggle("7-day history", isOn: $showHistory, available: historyReady,
                       note: "Builds up as Tokei runs: one point per limit every 15 minutes.")
            }
            FoldedSection("Refresh") { RefreshSettings() }
            FoldedSection("Alerts") { AlertSettings() }
            FoldedSection("Login and updates") { LoginAndUpdateSettings() }
        }
        .formStyle(.grouped)
    }

    /// A toggle whose data may not exist yet says so, instead of silently doing nothing.
    private func toggle(_ title: String, isOn: Binding<Bool>, available: Bool, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            if !available {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A section that starts closed and remembers being opened; its header is the disclosure button.
private struct FoldedSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @AppStorage private var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        _open = AppStorage(wrappedValue: false, "settings.open.\(title)")
    }

    var body: some View {
        Section {
            if open { content }
        } header: {
            Button {
                withAnimation(reduceMotion ? nil : .smooth) { open.toggle() }
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint(open ? "Hides these settings" : "Shows these settings")
        }
    }
}
