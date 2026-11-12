import Carbon.HIToolbox
import SwiftUI

/// Click, then press the keys. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @AppStorage(Prefs.hotKeyKey) private var stored = ""
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    private var shortcut: HotKey.Shortcut? { HotKey.Shortcut(stored: stored) }

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                Button(recording ? "Press keys…" : shortcut?.display ?? "Record") {
                    recording ? stop() : start()
                }
                if shortcut != nil, !recording {
                    Button {
                        stored = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                }
            }
        } label: {
            Text("Open panel shortcut")
            if let problem {
                Text(problem).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete, kVK_ForwardDelete:
                stored = ""
                stop()
            default:
                guard let shortcut = HotKey.Shortcut(event: event) else {
                    problem = "Include ⌃ or ⌥."
                    NSSound.beep()
                    return nil
                }
                if shortcut != HotKey.Shortcut(stored: stored), !HotKey.isAvailable(shortcut) {
                    problem = "\(shortcut.display) is taken by another app."
                    NSSound.beep()
                    return nil
                }
                stored = shortcut.stored
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
