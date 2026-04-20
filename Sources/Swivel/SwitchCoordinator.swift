import AppKit

/// Owns the "a switch is in flight" flag and runs the swap on a background
/// queue so the UI thread stays responsive. Exists to keep AppDelegate out
/// of the business of guarding reentrancy and juggling GCD.
///
/// A second call while a switch is already running is rejected with a beep,
/// not queued — queuing would let two overlapping swaps interleave their
/// snapshot/restore steps against the same Claude folder.
final class SwitchCoordinator {
    private let manager: ProfileManager
    private var isSwitching = false   // main-thread only

    init(manager: ProfileManager) {
        self.manager = manager
    }

    /// All callbacks fire on the main thread. `preflight` runs synchronously
    /// on main before the swap starts; return false to abort (e.g. the user
    /// cancelled a confirmation). If the target is already active, or a
    /// switch is already in flight, the call is a no-op beep.
    func performSwitch(
        to name: String,
        preflight: () -> Bool,
        onStart: @escaping () -> Void,
        onProgress: @escaping (String) -> Void,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        if isSwitching {
            NSSound.beep()
            return
        }
        if name == manager.activeProfile() {
            NSSound.beep()
            return
        }
        guard preflight() else { return }

        isSwitching = true
        onStart()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.manager.switchTo(profile: name) { status in
                    DispatchQueue.main.async { onProgress(status) }
                }
                DispatchQueue.main.async {
                    self.isSwitching = false
                    onSuccess()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSwitching = false
                    onFailure(error)
                }
            }
        }
    }
}
