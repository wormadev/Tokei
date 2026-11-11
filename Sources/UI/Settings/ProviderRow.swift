import SwiftUI

/// Mark, name, panel switch, and what the provider is doing right now.
struct ProviderRow: View {
    let id: ProviderID
    let refresher: Refresher
    @AppStorage private var enabled: Bool
    @AppStorage(Prefs.showAccountKey) private var showAccount = true

    init(id: ProviderID, refresher: Refresher) {
        self.id = id
        self.refresher = refresher
        _enabled = AppStorage(wrappedValue: true, Prefs.enabledKey(id))
    }

    private var installed: Bool { refresher.installed.contains(id) }
    private var state: ProviderState? { refresher.states[id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(mark).resizable().renderingMode(.template).scaledToFit().frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(id.name).font(.headline)
                Spacer()
                Toggle("Show \(id.name) in the panel", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!installed)
                    .onChange(of: enabled) { _, on in
                        // Turning a provider on is an explicit action: it may read the Keychain.
                        if on { Task { await refresher.refresh(id, userInitiated: true) } }
                    }
            }
            Group {
                status.font(.callout)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(id.name) status")
        }
        .help(source)
    }

    private var mark: String {
        switch id {
        case .claude: "ClaudeMark"
        case .codex: "CodexMark"
        }
    }

    private var source: String {
        switch id {
        case .claude: "Reads Claude Code's sign-in from the Keychain, the same way Claude Code does. No prompts."
        case .codex: "Reads \(CodexProvider.authFile.path(percentEncoded: false)) from the Codex CLI."
        }
    }

    private var failing: Bool {
        guard let state, state.error != nil else { return false }
        return state.needsSignIn || state.snapshot == nil
    }

    /// Symbol and wording differ per state, so color is never the only signal.
    @ViewBuilder private var status: some View {
        if !installed {
            Label("Not installed", systemImage: "xmark.circle").foregroundStyle(.secondary)
        } else if !enabled {
            Label("Hidden from the panel", systemImage: "eye.slash").foregroundStyle(.secondary)
        } else if failing {
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if state?.snapshot != nil {
            Label {
                Text("Connected")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label("Not checked yet", systemImage: "clock").foregroundStyle(.secondary)
        }
    }

    /// Markdown so `claude` renders as code. The account email only when the panel shows it too.
    private var detail: LocalizedStringKey? {
        if !installed {
            return switch id {
            case .claude: "Install Claude Code and sign in with `claude`. Tokei picks it up within a minute."
            case .codex: "Install the Codex CLI (`brew install --cask codex`) and run `codex login`."
            }
        }
        guard enabled else { return nil }
        if failing, let error = state?.error { return LocalizedStringKey(error) }
        if showAccount, let user = state?.snapshot?.account.user { return "Signed in as \(user)" }
        return nil
    }
}
