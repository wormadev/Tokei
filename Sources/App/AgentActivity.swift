import CoreServices
import Foundation

/// Last time Claude Code / Codex wrote a session log. FSEvents on the log folders: no polling,
/// file contents are never read.
@MainActor
final class AgentActivity {
    private(set) var lastActivity: [ProviderID: Date] = [:]
    private var streams: [ProviderID: FSEventStreamRef] = [:]
    /// Batches the per-line appends of a busy session into one event.
    private let latency: CFTimeInterval

    init(latency: CFTimeInterval = 10) {
        self.latency = latency
    }

    /// Starts watching folders that exist now; called every tick so a folder created later
    /// (first run of the CLI) gets picked up.
    func watch(_ folders: [ProviderID: URL]) {
        for (id, folder) in folders where streams[id] == nil && FileManager.default.fileExists(atPath: folder.path) {
            if let stream = makeStream(id, folder) { streams[id] = stream }
        }
    }

    private func makeStream(_ id: ProviderID, _ folder: URL) -> FSEventStreamRef? {
        let box = Unmanaged.passRetained(Box(id: id, activity: self))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { box.activity?.lastActivity[box.id] = .now }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else {
            box.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        return stream
    }

    private final class Box {
        let id: ProviderID
        weak var activity: AgentActivity?

        init(id: ProviderID, activity: AgentActivity) {
            self.id = id
            self.activity = activity
        }
    }

    /// Agent-aware schedule: every 2 min while an agent wrote in the last 5 min, else 15 min.
    nonisolated static func interval(lastActivity: Date?, now: Date) -> TimeInterval {
        guard let lastActivity, now.timeIntervalSince(lastActivity) < 5 * 60 else { return 15 * 60 }
        return 2 * 60
    }
}
