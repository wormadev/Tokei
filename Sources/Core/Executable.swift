import Foundation

enum Executable {
    static func exists(_ name: String) -> Bool {
        path(name) != nil
    }

    /// GUI apps get a minimal PATH, so also look where CLIs are usually installed.
    static func path(_ name: String) -> URL? {
        searchPath.map { URL(fileURLWithPath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
            "\(home)/.claude/local", "\(home)/Library/pnpm", "\(home)/.volta/bin", "\(home)/.local/share/mise/shims", "\(home)/.asdf/shims",
        ]
        return path + common + [newestNVMBin(home: home)].compactMap(\.self)
    }

    private static func newestNVMBin(home: String) -> String? {
        let versions = "\(home)/.nvm/versions/node"
        let newest = (try? FileManager.default.contentsOfDirectory(atPath: versions))?
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
        return newest.map { "\(versions)/\($0)/bin" }
    }

    struct TimedOut: LocalizedError {
        let timeout: Duration
        var errorDescription: String? { "it didn't finish within \(timeout.components.seconds) seconds" }
    }

    /// Output is discarded. The full search path goes along so npm installs find `node`.
    /// Throws `TimedOut` when it had to be stopped.
    static func run(_ url: URL, _ arguments: [String], timeout: Duration = .seconds(30)) async throws {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": searchPath.joined(separator: ":")]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = ContinuousClock.now
        let deadline = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
            try await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if ContinuousClock.now - started >= timeout { throw TimedOut(timeout: timeout) }
    }
}
