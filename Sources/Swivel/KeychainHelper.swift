import Foundation

enum KeychainError: LocalizedError {
    case runFailed(Int32, String)
    var errorDescription: String? {
        switch self {
        case .runFailed(let code, let msg): return "security exited \(code): \(msg)"
        }
    }
}

/// Thin wrapper around the `security` CLI for the one keychain item we care
/// about: Claude Desktop's Safe Storage encryption key, which is what Electron
/// uses to encrypt the Cookies file. Swapping cookies without this key yields
/// an app that can't read its own session data.
enum KeychainHelper {
    private static let service = "Claude Safe Storage"
    private static let account = "Claude Key"

    static func readSafeStorageKey() throws -> String {
        let (status, out, err) = run("/usr/bin/security", args: [
            "find-generic-password", "-s", service, "-a", account, "-w"
        ])
        if status != 0 { throw KeychainError.runFailed(status, err) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeSafeStorageKey(_ key: String) throws {
        // Strategy: plain `-U` update in place — no `-A`, no `-T`.
        //
        // This updates only the stored value, preserving the existing ACL
        // apps list AND the partition list. Why that matters:
        //
        //   - `-A` resets the partition list to `apple-tool:` only, stripping
        //     `teamid:Q6L2SF6YDW`. The next Claude launch then prompts
        //     "Claude wants to access..." because its team ID is no longer
        //     trusted for this item.
        //
        //   - delete+add does the same thing — a fresh item has a fresh
        //     partition list without Claude's team ID.
        //
        //   - `-U` combined with `-T` or `-A` triggers "change access
        //     permissions" prompts every call, because modifying ACL needs
        //     auth even when you already have access.
        //
        // Plain `-U` sidesteps all of this. The item keeps whatever ACL it
        // already has (Claude's team ID in partition list; `/usr/bin/security`
        // in apps list after the user's one-time "Always Allow" on first
        // read), and the value is silently updated.
        let (status, _, err) = run("/usr/bin/security", args: [
            "add-generic-password",
            "-s", service,
            "-a", account,
            "-w", key,
            "-U"
        ])
        if status != 0 { throw KeychainError.runFailed(status, err) }
    }

    private static func run(_ launchPath: String, args: [String]) -> (Int32, String, String) {
        let proc = Process()
        proc.launchPath = launchPath
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch {
            return (-1, "", "failed to launch: \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, out, err)
    }
}
