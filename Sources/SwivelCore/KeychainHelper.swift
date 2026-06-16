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

    // NOTE: this helper is intentionally read-only. Swivel never writes to the
    // keychain (see SECURITY.md): a `security` write would rebuild the item's
    // partition list from our code signature, stripping Claude's team ID and
    // triggering a permission prompt on Claude's next launch.

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
