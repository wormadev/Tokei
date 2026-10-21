import Foundation

enum Executable {
    /// GUI apps get a minimal PATH, so also look where CLIs are usually installed.
    static func exists(_ name: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = path + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        return dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }
}
