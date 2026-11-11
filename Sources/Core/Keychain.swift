import Foundation
import Security
import Synchronization

enum Keychain {
    enum ReadResult: Equatable {
        case found(Data)
        case notFound
        /// Denied, cancelled, or killed at the deadline: a dialog was likely involved.
        case failed
    }

    /// Reads a generic password through /usr/bin/security. Claude Code's item trusts that tool,
    /// so this read is silent, while a direct SecItem read from Tokei kept asking again after
    /// Claude Code refreshed its token.
    static func readViaSecurityTool(service: String) -> ReadResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failed }
        // A Keychain dialog can keep the tool waiting forever. Killing it ends the read below.
        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        deadline.cancel()
        process.waitUntilExit()
        // security exits 44 (errSecItemNotFound) when there is no such item.
        if process.terminationReason == .exit, process.terminationStatus == 44 { return .notFound }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return .failed }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .notFound : .found(Data(trimmed.utf8))
    }

    /// Whether the default (login) keychain is unlocked, asked without prompting. Deprecated,
    /// but SecItem has no lock-state query that can't show a dialog.
    static func isDefaultUnlocked() -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return false }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
        return status & SecKeychainStatus(kSecUnlockStateStatus) != 0
    }

    /// Attributes-only lookup: never returns the secret, never prompts.
    static func exists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}

/// Decides whether a Keychain read may run. Background reads skip a locked keychain, and the
/// first failed read stops them for the rest of the run: at most one dialog until the user asks.
final class KeychainGate: Sendable {
    private let latched = Mutex(false)

    var isLatched: Bool { latched.withLock { $0 } }

    /// nil: no such item. Throws instead of reading when a background read could prompt.
    func read(userInitiated: Bool, isUnlocked: () -> Bool, read: () -> Keychain.ReadResult) throws -> Data? {
        if !userInitiated {
            if isLatched { throw ProviderError.keychainBlocked }
            if !isUnlocked() { throw ProviderError.keychainLocked }
        }
        switch read() {
        case let .found(data):
            if userInitiated { latched.withLock { $0 = false } }
            return data
        case .notFound:
            if userInitiated { latched.withLock { $0 = false } }
            return nil
        case .failed:
            latched.withLock { $0 = true }
            throw ProviderError.keychainBlocked
        }
    }
}
