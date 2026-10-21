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
            Text(refresher.installed.isEmpty ? "Install Claude Code or Codex to see usage" : "No providers enabled").font(.callout)
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
                // Always shown: a banked reset is the one number you can act on.
                if let banked = snapshot.banked {
                    BankedRow(id: id, banked: banked, connector: connector, now: now)
                }
                if let notice = connector.notices[id] {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
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

/// Banked resets, with a Reset button that needs a second click: spending one can't be undone.
struct BankedRow: View {
    let id: ProviderID
    let banked: BankedResets
    let connector: Connector
    let now: Date
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            Label(banked.text(now: now), systemImage: "arrow.counterclockwise.circle")
                .font(.callout)
            Spacer()
            if let grantID = banked.grantID {
                if connector.redeeming.contains(id) {
                    ProgressView().controlSize(.small)
                } else if confirming {
                    Button("Cancel") { confirming = false }
                    Button("Use reset") {
                        confirming = false
                        connector.redeem(id, grantID: grantID)
                    }
                    .tint(.orange)
                } else {
                    Button("Reset") { confirming = true }
                        .help("Resets your session and weekly limits now")
                }
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .task(id: confirming) {
            // Back out of the confirm state on its own if left alone.
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(5))
            confirming = false
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let history: [History.Point]
    let now: Date
    let absoluteResets: Bool
    @AppStorage(Prefs.usageDisplayKey) private var usageDisplay = UsageDisplay.used.rawValue
    @AppStorage(Prefs.showPaceKey) private var showPace = true

    private var display: UsageDisplay { UsageDisplay(rawValue: usageDisplay) ?? .used }

    /// Hidden once the limit is used up: "in deficit" adds nothing then.
    private var pace: Pace? {
        guard showPace, window.used < 1 else { return nil }
        return Pace(window: window, now: now)
    }

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
                Text(display == .used ? display.text(window.used) : "\(display.text(window.used)) left")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: display.value(window.used)))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            UsageBar(used: window.used, display: display, pace: pace)
            if let pace {
                HStack {
                    Text(pace.summary)
                        .foregroundStyle(pace.delta > 0 && !pace.isOnTrack ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    Spacer()
                    Text(pace.forecast(now: now)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if history.count > 1 {
                Sparkline(points: history).frame(height: 24)
            }
        }
        .animation(.smooth, value: window.used)
    }
}

struct UsageBar: View {
    let used: Double
    var display: UsageDisplay = .used
    var pace: Pace?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule()
                    .fill(Design.color(for: used))
                    // Color stays keyed to usage: red means nearly out in either mode.
                    .frame(width: proxy.size.width * min(max(display.value(used), 0), 1))
                // Where usage would be with an even spread over the window.
                if let pace, !pace.isOnTrack {
                    Capsule()
                        .fill(Design.paceColor(pace))
                        .frame(width: 2, height: 10)
                        .offset(x: proxy.size.width * display.value(pace.expected) - 1)
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue("\(Int((used * 100).rounded())) percent used")
    }
}
