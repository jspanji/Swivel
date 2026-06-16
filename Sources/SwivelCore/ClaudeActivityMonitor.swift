import AppKit

/// Tracks whether the user is actively in Claude right now, so a switch can
/// warn before it quits Claude and discards an in-progress message.
///
/// Combines two signals: `didActivateApplication` notifications (catch the
/// transition into Claude) and a 1-second poll (catches "user has been typing
/// in Claude continuously for minutes" — the last activation event might be
/// far in the past, so notifications alone produce a false negative).
final class ClaudeActivityMonitor {
    private let bundleID = "com.anthropic.claudefordesktop"
    private let inUseWindow: TimeInterval = 5

    private var lastFrontmostAt: Date?
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    func start() {
        refresh()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == self.bundleID
            else { return }
            self.lastFrontmostAt = Date()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        pollTimer?.invalidate()
    }

    private func refresh() {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            lastFrontmostAt = Date()
        }
    }

    /// Best-effort: is the user likely mid-conversation in Claude right now?
    ///   - Claude is running AND currently frontmost, OR
    ///   - Claude was frontmost within the last `inUseWindow` seconds.
    func likelyInUse() -> Bool {
        guard ClaudeAppController.isRunning() else { return false }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            return true
        }
        if let last = lastFrontmostAt,
           Date().timeIntervalSince(last) < inUseWindow {
            return true
        }
        return false
    }
}
