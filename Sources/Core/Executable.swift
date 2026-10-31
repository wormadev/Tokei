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
        return path + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
    }

    /// Output is discarded. The full search path goes along so npm installs find `node`.
    static func run(_ url: URL, _ arguments: [String], timeout: Duration = .seconds(30)) async throws {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": searchPath.joined(separator: ":")]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let deadline = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
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
    }
}
