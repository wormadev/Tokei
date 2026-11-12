import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's hot key API, which needs no Accessibility permission.
@MainActor
final class HotKey {
    /// Stored as "keyCode,carbonModifiers,display".
    struct Shortcut: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var display: String

        init(keyCode: UInt32, modifiers: UInt32, display: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.display = display
        }

        init?(stored: String?) {
            let parts = (stored ?? "").split(separator: ",", maxSplits: 2).map(String.init)
            guard parts.count == 3, let keyCode = UInt32(parts[0]), let modifiers = UInt32(parts[1]) else { return nil }
            self.init(keyCode: keyCode, modifiers: modifiers, display: parts[2])
        }

        var stored: String { "\(keyCode),\(modifiers),\(display)" }

        /// Nil without ⌃ or ⌥: plain keys would swallow typing, and ⌘ or ⇧⌘ alone would take
        /// over app shortcuts like ⌘W everywhere, since a hot key wins over every menu.
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.control, .option]).isEmpty else { return nil }
            var carbon: UInt32 = 0
            var symbols = ""
            if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
            if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
            if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
            let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
            guard !key.isEmpty else { return nil }
            self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key)
        }
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: Shortcut?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action() }
            return noErr
        }, 1, &spec, context, &handler)
        apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func apply() {
        let shortcut = Shortcut(stored: UserDefaults.standard.string(forKey: Prefs.hotKeyKey))
        guard shortcut != registered else { return }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = shortcut
        guard let shortcut else { return }
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, Self.id, GetApplicationEventTarget(), 0, &ref)
    }

    private static let id = EventHotKeyID(signature: OSType(0x544B_4549), id: 1)

    /// False when another app holds the combination.
    static func isAvailable(_ shortcut: Shortcut) -> Bool {
        var trial: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: OSType(0x544B_4549), id: 2), GetApplicationEventTarget(), 0, &trial)
        if let trial { UnregisterEventHotKey(trial) }
        return status == noErr
    }
}
