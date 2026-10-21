import Foundation

enum Executable {
    static func exists(_ name: String) -> Bool {
        path(name) != nil
    }

    /// GUI apps get a minimal PATH, so also look where CLIs are usually installed.
    static func path(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = path + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        return dirs.map { URL(fileURLWithPath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
