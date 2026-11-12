import SwiftUI

/// A slice of desktop: the menu bar item and the panel, drawn by the same code as the real ones.
/// Display only: it never refreshes, so it can't cause network or Keychain work.
struct PanelPreview: View {
    let refresher: Refresher
    let connector: Connector

    @AppStorage(Prefs.showPaceKey) private var showPace = true
    @AppStorage(Prefs.showAccountKey) private var showAccount = true
    @AppStorage(Prefs.showStatusKey) private var showStatus = true
    @AppStorage(Prefs.showDetailsKey) private var showDetails = false
    @AppStorage(Prefs.showModelLimitsKey) private var showModelLimits = true
    @AppStorage(Prefs.showHistoryKey) private var showHistory = false
    @AppStorage(Prefs.providerOrderKey) private var orderRaw = ""
    /// `refresher.enabled` reads UserDefaults, which SwiftUI doesn't observe; bump on any change.
    @State private var defaultsChanges = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = defaultsChanges
        VStack(spacing: 0) {
            MenuBarPreview(refresher: refresher)
                .background(.bar)
            Divider()
            ScrollView {
                panel
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(.fill.quinary)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            defaultsChanges += 1
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Tokei").font(.headline)
                Spacer()
                Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            if refresher.enabled.isEmpty {
                Text(refresher.installed.isEmpty ? "Install Claude Code or Codex to see usage" : "No providers enabled")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .card()
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 8) {
                        ForEach(refresher.enabled) { id in
                            ProviderCard(id: id, state: refresher.states[id] ?? ProviderState(), status: refresher.statuses[id],
                                         history: refresher.history, connector: connector, now: context.date)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: Design.panelWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: Design.panelRadius))
        // The cards' buttons (Reset, Fix) act for real; here they are pictures.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Panel preview")
        .animation(reduceMotion ? nil : .smooth, value: [showPace, showAccount, showStatus, showDetails, showModelLimits, showHistory])
        .animation(reduceMotion ? nil : .smooth, value: orderRaw)
        .animation(reduceMotion ? nil : .smooth, value: refresher.enabled)
    }
}

/// The status item as it renders now, beside stand-in menu bar neighbors.
private struct MenuBarPreview: View {
    let refresher: Refresher
    /// The status item reads UserDefaults directly; bump on any change to redraw.
    @State private var defaultsChanges = 0
    @AppStorage(Prefs.providerOrderKey) private var order = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same as the real items: one per provider when set to each.
    private var icons: [MenuBarIcon] {
        let _ = (defaultsChanges, order)
        let config = MenuBarConfig.current
        let enabled = refresher.enabled
        let providers: [ProviderID?] = config.each && !enabled.isEmpty ? enabled : [nil]
        return providers.map { provider in
            var itemConfig = config
            if let provider { itemConfig.provider = provider }
            return MenuBarIcon.make(states: refresher.states, enabled: enabled, config: itemConfig, display: .current)
        }
    }

    var body: some View {
        let icons = icons
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "wifi").accessibilityHidden(true)
            Image(systemName: "battery.75percent").accessibilityHidden(true)
            HStack(spacing: 8) {
                ForEach(icons.indices, id: \.self) { index in
                    Image(nsImage: icons[index].image()).renderingMode(.template)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 22)
            .background(.fill.tertiary, in: .rect(cornerRadius: Design.innerRadius))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Menu bar preview")
            .accessibilityValue(icons.flatMap(\.lines).joined(separator: ", "))
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
            }
            .accessibilityHidden(true)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .animation(reduceMotion ? nil : .smooth, value: icons)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            defaultsChanges += 1
        }
    }
}
