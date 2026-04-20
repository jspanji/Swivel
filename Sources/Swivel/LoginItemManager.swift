import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for controlling whether
/// Swivel launches at login. Works on macOS 13+.
///
/// Requires the app bundle to be installed (typically in /Applications)
/// and properly signed — ad-hoc signing from our build script is enough
/// for registration to succeed in practice.
enum LoginItemManager {
    static var isAvailable: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func enable() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.register()
        }
    }

    static func disable() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Flip the current state. Returns the resulting enabled state and any
    /// error that occurred (in which case state may be unchanged).
    static func toggle() -> (enabled: Bool, error: Error?) {
        do {
            if isEnabled {
                try disable()
                return (false, nil)
            } else {
                try enable()
                return (true, nil)
            }
        } catch {
            return (isEnabled, error)
        }
    }
}
