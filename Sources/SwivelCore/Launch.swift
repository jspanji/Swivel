import AppKit

/// Entry point the thin `Swivel` executable calls. Lives in the library so
/// the executable target is just `main.swift` → `launchSwivel()`, which keeps
/// all logic in `SwivelCore` where the test target can reach it via
/// `@testable import`.
public func launchSwivel() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()   // blocks until quit; `delegate` stays retained for the run
}
