import AppKit

enum ClaudeAppController {
    private static let bundleID = "com.anthropic.claudefordesktop"

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func quit() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    /// Force-terminate Claude if it won't quit cleanly.
    static func forceQuit() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.forceTerminate()
        }
    }

    /// Block until Claude is no longer running, or timeout expires.
    /// Escalates to forceTerminate halfway through.
    @discardableResult
    static func waitUntilQuit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let escalateAt = Date().addingTimeInterval(timeout / 2)
        var escalated = false
        while Date() < deadline {
            if !isRunning() { return true }
            if !escalated, Date() > escalateAt {
                forceQuit()
                escalated = true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !isRunning()
    }

    static func launch() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
    }
}
