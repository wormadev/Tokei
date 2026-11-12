import Combine
import SwiftUI

/// Set on each open from the status item's screen, which can differ from NSScreen.main.
@MainActor
@Observable
final class PanelLayout {
    var maxHeight: CGFloat = (NSScreen.main?.visibleFrame.height ?? 800) - 80
}

struct PanelView: View {
    let refresher: Refresher
    let connector: Connector
    let layout: PanelLayout
    let openSettings: () -> Void
    let checkForUpdates: () -> Void
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
                                ProviderCard(id: id, state: refresher.states[id] ?? ProviderState(), status: refresher.statuses[id], history: refresher.history, connector: connector, now: context.date)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                // Grow with content, scroll only once the panel would run off screen.
                .frame(maxHeight: layout.maxHeight)
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
            if let version = Updater.shared.availableVersion {
                Button("Update to \(version)", action: checkForUpdates)
                    .font(.callout)
                    .help("Tokei \(version) is available")
            }
            Button(action: refresher.refreshAll) {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !refresher.refreshing.isEmpty)
                    .frame(width: 24, height: 24)
            }
            .keyboardShortcut("r")
            .help("Refresh now (⌘R)")
            .accessibilityLabel("Refresh")
            Menu {
                Button("Settings…", action: openSettings).keyboardShortcut(",")
                if Updater.shared.isConfigured {
                    Button("Check for Updates…", action: checkForUpdates)
                }
                Divider()
                Button("Quit Tokei") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(refresher.installed.isEmpty ? "Install Claude Code or Codex to see usage here." : "All providers are hidden.").font(.callout)
            Button("Open Settings", action: openSettings)
        }
        .frame(maxWidth: .infinity)
        .card()
    }
}

struct ProviderCard: View {
    let id: ProviderID
    let state: ProviderState
    let status: ServiceStatus?
    let history: History
    let connector: Connector
    let now: Date

    @AppStorage(Prefs.showAccountKey) private var showAccount = true
    @AppStorage(Prefs.showDetailsKey) private var showDetails = false
    @AppStorage(Prefs.showModelLimitsKey) private var showModelLimits = true
    @AppStorage(Prefs.showHistoryKey) private var showHistory = false
    @AppStorage(Prefs.showStatusKey) private var showStatus = true
    @AppStorage(Prefs.showBankedKey) private var showBanked = true

    private var failure: String? { connector.renewFailure(id, lastSuccess: state.snapshot?.fetchedAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
            if showStatus, let status {
                StatusRow(status: status)
            }
            if state.needsSignIn {
                signInRow
            }
            if let snapshot = state.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    if showAccount, let user = snapshot.account.user {
                        Text(user).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(snapshot.windows.filter { $0.kind == .primary || showModelLimits }) { window in
                        WindowRow(
                            window: window,
                            history: showHistory ? history.points(id, window.id) : [],
                            stale: state.needsSignIn,
                            now: now
                        )
                    }
                    if snapshot.windows.isEmpty {
                        Text("No limits reported").font(.caption).foregroundStyle(.secondary)
                    }
                }
                // Old numbers until the sign-in works again, like the menu bar.
                .opacity(state.needsSignIn ? 0.5 : 1)
                if showBanked, let banked = snapshot.resets, !banked.isEmpty {
                    ForEach(banked, id: \.name) { resets in
                        BankedRow(id: id, resets: resets, usable: !state.needsSignIn, connector: connector, now: now)
                    }
                }
                if let notice = connector.notices[id] {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
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
            } else if let error = state.error, !state.needsSignIn {
                // Markdown so `claude` renders as code.
                Label(LocalizedStringKey(error), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if state.transient == true, state.snapshot != nil, let error = state.error {
                // Nothing to fix: say it calmly and keep the last numbers.
                Text(state.keychainUnavailable ? error : "Couldn't update\(state.retryAt.map { ". Retrying \(TimeText.reset($0, now: now, absolute: false))" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The one problem only the user can fix, so it sits at the top with its fix.
    private var signInRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(LocalizedStringKey(state.error ?? ""), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if state.snapshot != nil, let command = Connector.statusCommands[id] {
                    if connector.renewing.contains(id) {
                        ProgressView().controlSize(.mini)
                    } else if failure != nil {
                        Button("Open Terminal") { connector.openTerminal(id) }
                            .foregroundStyle(.tint)
                            .help("Starts \(command.cli) in Terminal")
                    } else {
                        Button("Renew") { Task { await connector.renewSignIn(id, userInitiated: true) } }
                            .foregroundStyle(.tint)
                            .help("Runs \(command.cli) \(command.arguments.joined(separator: " "))")
                    }
                }
            }
            .font(.callout)
            .buttonStyle(.borderless)
            if let failure {
                Text(LocalizedStringKey(failure)).font(.caption).foregroundStyle(.secondary)
            }
        }
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

/// An open incident on the provider's status page. Opens the incident on click.
struct StatusRow: View {
    let status: ServiceStatus
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(status.link)
        } label: {
            Label(status.title, systemImage: "exclamationmark.triangle.fill")
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(status.severity == .major ? Color.red : Color.orange)
        .help("Open the status page")
    }
}

/// One kind of banked reset. Use asks first: a spent reset is gone.
struct BankedRow: View {
    let id: ProviderID
    let resets: BankedResets
    /// False while the sign-in is expired: spending would fail.
    let usable: Bool
    let connector: Connector
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: resets.kind == .fable ? "sparkles" : "arrow.counterclockwise")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(resets.name).font(.callout)
                Text(resets.detail(now: now)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if usable, let grantID = resets.grantID {
                if connector.redeeming.contains(id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Use") {
                        if ResetConfirmation.confirm(resets) { connector.redeem(id, resets, grantID: grantID) }
                    }
                    .font(.callout)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                }
            }
        }
    }
}

/// A real dialog rather than an inline second click: a double-click can't spend a reset.
@MainActor
enum ResetConfirmation {
    static func confirm(_ resets: BankedResets) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Use a \(resets.name.lowercased())?"
        let left = resets.count - 1
        alert.informativeText = "\(resets.effect) You'll have \(left == 0 ? "none" : "\(left)") left."
        alert.addButton(withTitle: "Use Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        // Above the panel, which floats at status bar level.
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let history: [History.Point]
    /// Old numbers behind an expired sign-in: a projection from them would mislead.
    var stale = false
    let now: Date
    @AppStorage(Prefs.usageDisplayKey) private var usageDisplay = UsageDisplay.used.rawValue
    @AppStorage(Prefs.absoluteResetsKey) private var absoluteResets = false
    @AppStorage(Prefs.showPaceKey) private var showPace = true

    private var display: UsageDisplay { UsageDisplay(rawValue: usageDisplay) ?? .used }

    /// The saved number belongs to the window before; the next refresh brings the new one.
    private var hasReset: Bool { window.hasReset(now: now) }

    /// Hidden once the limit is used up: a projection adds nothing then.
    private var pace: Pace? {
        guard showPace, !stale, window.used < 1, !hasReset else { return nil }
        return Pace(window: window, now: now)
    }

    /// Name and projection on top, bar, then amount and reset time underneath.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.body.weight(.semibold))
                Spacer()
                if let pace {
                    Text(pace.headline(now: now))
                        .font(.callout)
                        .foregroundStyle(pace.runsOut ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
            }
            if hasReset {
                Capsule().fill(.fill.tertiary).frame(height: 8)
            } else {
                UsageBar(label: window.label, used: window.used, display: display, pace: pace)
            }
            HStack(alignment: .firstTextBaseline) {
                if hasReset, let resets = window.resetsAt {
                    Text("Reset \(TimeText.ago(resets, now: now))").foregroundStyle(.secondary)
                } else {
                    amountAndReset
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            if history.count > 1 {
                Sparkline(points: history).frame(height: 24)
            }
        }
        .animation(.smooth, value: window.used)
    }

    @ViewBuilder private var amountAndReset: some View {
            Button {
                usageDisplay = (display == .used ? UsageDisplay.remaining : .used).rawValue
            } label: {
                Text(display == .used ? "\(display.text(window.used)) used" : "\(display.text(window.used)) left")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: display.value(window.used)))
            }
            .help(display == .used ? "Show what's left" : "Show what's used")
            Spacer()
            if let resets = window.resetsAt {
                Button {
                    absoluteResets.toggle()
                } label: {
                    Text("Resets \(TimeText.reset(resets, now: now, absolute: absoluteResets))")
                        .foregroundStyle(.secondary)
                }
                .help(absoluteResets ? "Show time until reset" : "Show reset as clock time")
            } else if window.used == 0 {
                // The window starts with the first message, so there is no reset time yet.
                Text("Not started").foregroundStyle(.secondary)
            }
    }
}

struct UsageBar: View {
    let label: String
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
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((used * 100).rounded())) percent used")
    }
}
