import Combine
import SwiftUI

struct PanelView: View {
    let refresher: Refresher
    let connector: Connector
    let openSettings: () -> Void
    /// `refresher.enabled` reads UserDefaults, which SwiftUI doesn't observe; bump on any change.
    @State private var defaultsChanges = 0

    var body: some View {
        let _ = defaultsChanges
        VStack(alignment: .leading, spacing: 8) {
            header
            if refresher.enabled.isEmpty {
                empty
            } else {
                // Coarse clock for "ago"/"resets in" labels: they change on the minute, not per frame.
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 8) {
                            ForEach(refresher.enabled) { id in
                                ProviderCard(id: id, state: refresher.states[id] ?? ProviderState(), history: refresher.history, connector: connector, now: context.date)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                // Grow with content, scroll only once the panel would run off screen.
                .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) - 80)
            }
        }
        .padding(12)
        .frame(width: Design.panelWidth)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            defaultsChanges += 1
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Tokei").font(.headline)
            Spacer()
            Button(action: refresher.refreshAll) {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !refresher.refreshing.isEmpty)
                    .frame(width: 24, height: 24)
            }
            .keyboardShortcut("r")
            .help("Refresh now (⌘R)")
            Menu {
                Button("Settings…", action: openSettings).keyboardShortcut(",")
                Divider()
                Button("Quit Tokei") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No providers enabled").font(.callout)
            Button("Open Settings", action: openSettings)
        }
        .frame(maxWidth: .infinity)
        .card()
    }
}

struct ProviderCard: View {
    let id: ProviderID
    let state: ProviderState
    let history: History
    let connector: Connector
    let now: Date

    @AppStorage(Prefs.showAccountKey) private var showAccount = true
    @AppStorage(Prefs.showDetailsKey) private var showDetails = false
    @AppStorage(Prefs.showModelLimitsKey) private var showModelLimits = false
    @AppStorage(Prefs.showHistoryKey) private var showHistory = false
    @AppStorage(Prefs.absoluteResetsKey) private var absoluteResets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
            if let snapshot = state.snapshot {
                if showAccount, let user = snapshot.account.user {
                    Text(user).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                ForEach(snapshot.windows.filter { $0.kind == .primary || showModelLimits }) { window in
                    WindowRow(
                        window: window,
                        history: showHistory ? history.points(id, window.id) : [],
                        now: now,
                        absoluteResets: absoluteResets
                    )
                }
                if snapshot.windows.isEmpty {
                    Text("No limits reported").font(.caption).foregroundStyle(.secondary)
                }
                if showDetails, !snapshot.details.isEmpty {
                    ForEach(snapshot.details, id: \.label) { detail in
                        HStack {
                            Text(detail.label)
                            Spacer()
                            Text(detail.value).monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = connector.errors[id] ?? state.error {
                // Markdown so `claude` renders as code.
                Label(LocalizedStringKey(error), systemImage: state.snapshot == nil ? "info.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(state.snapshot == nil ? .secondary : Color.orange)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if state.needsConnect == true, let title = connector.actionTitle(id) {
                Button(title) { connector.connect(id) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var title: some View {
        HStack(spacing: 8) {
            Text(id.name).font(.headline)
            if showAccount, let plan = state.snapshot?.account.plan {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: .rect(cornerRadius: Design.innerRadius))
            }
            Spacer()
            if let fetched = state.snapshot?.fetchedAt {
                Text(TimeText.ago(fetched, now: now))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Last updated \(fetched.formatted(date: .abbreviated, time: .standard))")
            }
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let history: [History.Point]
    let now: Date
    let absoluteResets: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.callout)
                Spacer()
                if let resets = window.resetsAt {
                    Text("Resets \(TimeText.reset(resets, now: now, absolute: absoluteResets))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(Int((window.used * 100).rounded()))%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: window.used))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            UsageBar(used: window.used)
            if history.count > 1 {
                Sparkline(points: history).frame(height: 24)
            }
        }
        .animation(.smooth, value: window.used)
    }
}

struct UsageBar: View {
    let used: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule()
                    .fill(Design.color(for: used))
                    .frame(width: proxy.size.width * min(max(used, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue("\(Int((used * 100).rounded())) percent used")
    }
}
