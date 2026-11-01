import AppKit
import Observation
import Sparkle

/// Sparkle updates through tokei.worma.dev, which counts opted-in installs and redirects to the GitHub
/// releases feed. Feed URL and EdDSA public key live in Info.plist (project.yml); Debug has no key, so
/// Sparkle is never created and nothing is fetched.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    let isConfigured: Bool
    private(set) var checksAutomatically = false
    private(set) var sharesInstallCount = false
    /// Set when a scheduled check finds an update that Sparkle would otherwise show behind other windows.
    fileprivate(set) var availableVersion: String?

    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.isEmpty
    }

    /// At launch, so scheduled checks run. Not controller.startUpdater(): on a configuration error
    /// that opens a modal alert, which an agent app shows behind other windows.
    func start() {
        guard isConfigured, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate,
                                                      userDriverDelegate: delegate)
        self.controller = controller
        // Also catches the answer to Sparkle's permission prompt. Sparkle changes it on the main thread.
        observations = [
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial]) { updater, _ in
                MainActor.assumeIsolated { Updater.shared.checksAutomatically = updater.automaticallyChecksForUpdates }
            },
            // The prompt's "Include anonymous system profile" checkbox is the install-count opt-in.
            controller.updater.observe(\.sendsSystemProfile, options: [.initial]) { updater, _ in
                MainActor.assumeIsolated { Updater.shared.sharesInstallCount = updater.sendsSystemProfile }
            },
        ]
        do {
            try controller.updater.start()
        } catch {
            NSLog("Tokei: updater failed to start: %@", error.localizedDescription)
        }
    }

    func checkForUpdates() {
        guard let controller else { return }
        // While a session runs Sparkle only refocuses its open window; ours must come forward too.
        delegate.showInFront()
        controller.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    func setSharesInstallCount(_ on: Bool) {
        controller?.updater.sendsSystemProfile = on
    }
}

/// Sparkle calls both delegates on the main thread.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Cooperative `NSApp.activate()` is refused without a user event of ours behind it (launch-time
    /// permission prompt); activating through Launch Services is not.
    func showInFront() {
        NSApp.activate()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A random id per install, sent with every check once the user opts in, so the server can count
    /// distinct installs per day. Sparkle adds its own profile (versions, CPU) at most weekly.
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        guard updater.sendsSystemProfile else { return [] }
        let key = "installID"
        let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return [["key": "id", "value": id, "displayKey": "Install ID", "displayValue": id]]
    }

    /// An agent app's scheduled alert after launch opens behind other windows, where it goes unseen.
    /// Hold it and show "Update to …" in the panel instead; checkForUpdates() then brings it up.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        Updater.shared.availableVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        Updater.shared.availableVersion = nil
    }

    func standardUserDriverWillShowModalAlert() {
        showInFront()
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        showInFront()
        return true
    }
}
