import AppKit
import Carbon.HIToolbox
import Sparkle
import UserNotifications

extension NSColor {
    /// "#RRGGBB" sRGB hex string for persistence. Returns nil if the color
    /// can't be bridged to sRGB (extremely unusual — dynamic system colors
    /// resolve once converted).
    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parse "#RRGGBB" or "RRGGBB" back into an sRGB color.
    convenience init?(hexString: String) {
        var hex = hexString
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let manager = ProfileManager()
    private let statusChecker = ClaudeStatusChecker()
    private let hotkeys = HotkeyManager()
    private lazy var switcher = SwitchCoordinator(manager: manager)

    // UI layer: one observable model feeding both SwiftUI surfaces
    // (popover + desktop widget), and the AppKit controllers that host
    // them. Constructed in applicationDidFinishLaunching once the
    // status item exists.
    private lazy var viewModel = SwivelViewModel(manager: manager, statusChecker: statusChecker)
    private var statusItemController: StatusItemController?
    private var widgetController: DesktopWidgetController?

    // Sparkle handles auto-update end to end: it reads our appcast on
    // a background schedule, downloads the new build, verifies the
    // EdDSA signature against `SUPublicEDKey` from Info.plist, then
    // installs and relaunches. `startingUpdater: true` kicks off the
    // background scheduler immediately on init.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    // Tracks whether the user is mid-conversation in Claude, so a switch
    // can warn before discarding a draft.
    private let activityMonitor = ClaudeActivityMonitor()

    // Carbon-side modifier mask for ⌘⌥.
    private let cmdOpt = cmdKey | optionKey

    // Number-row virtual key codes 1..9, in visual order.
    private let numberKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
        kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
        kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Layer-backed so we can animate the pulse below. Has to
            // be set up front; flipping wantsLayer later invalidates
            // the drawing-heavy icon we've already installed.
            button.wantsLayer = true
            button.image = currentStatusIcon()
            button.imagePosition = .imageLeft
        }

        // Popover + right-click fallback take over the button's click
        // handling (the old NSMenu attached via `statusItem.menu`).
        let actions = makeUIActions()
        let controller = StatusItemController(
            statusItem: statusItem,
            rootView: PopoverRootView(model: viewModel, actions: actions),
            fallbackMenu: makeFallbackMenu()
        )
        controller.onWillShow = { [weak self] in
            // Same job menuWillOpen did: nearly-real-time status without
            // busy polling. Throttled inside ClaudeStatusChecker.
            self?.statusChecker.checkNow()
            self?.viewModel.refresh()
        }
        statusItemController = controller

        let widget = DesktopWidgetController(model: viewModel) { widgetController in
            WidgetRootView(
                model: self.viewModel,
                actions: actions,
                onToggleAlwaysOnTop: { [weak widgetController] in
                    widgetController?.toggleAlwaysOnTop()
                },
                onHide: { [weak widgetController] in
                    widgetController?.hide()
                }
            )
        }
        widget.onRefreshNeeded = { [weak self] in self?.viewModel.refresh() }
        widgetController = widget
        widget.restoreFromDefaults()

        refreshUI()

        // Start polling Anthropic's public status page. On each update:
        //   1. redraw the menu bar icon (status ray color changes),
        //   2. refresh the view model (textual status line + usage data),
        //   3. start/stop the attention pulse based on the new level.
        statusChecker.onUpdate = { [weak self] snapshot in
            guard let self = self else { return }
            self.refreshUI()
            self.updateStatusPulse(for: snapshot.level)
        }
        statusChecker.start()

        registerHotkeys()
        activityMonitor.start()

        // Ask once for permission to post "Switched to…" banners. Denial
        // is fine — `notify()` silently no-ops if the system rejects
        // the request. The prompt appears on first launch only.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    // MARK: - Global hotkeys

    /// Bind ⌘⌥1..9 to profiles in alphabetical order, and ⌘⌥` to flip
    /// between the current and previously-active profiles. Re-run whenever
    /// the profile list might have changed (save / delete).
    private var didWarnHotkeyFailure = false

    private func registerHotkeys() {
        hotkeys.unregisterAll()

        var failedSlots: [String] = []

        // Per-profile number hotkeys.
        let profiles = manager.listProfiles()
        for (idx, profile) in profiles.prefix(numberKeyCodes.count).enumerated() {
            let keyCode = numberKeyCodes[idx]
            let token = hotkeys.register(keyCode: keyCode, modifiers: cmdOpt) { [weak self] in
                self?.performSwitch(to: profile)
            }
            if token == nil { failedSlots.append("⌘⌥\(idx + 1)") }
        }

        // Flip-to-previous hotkey (⌘⌥`).
        let flipToken = hotkeys.register(keyCode: kVK_ANSI_Grave, modifiers: cmdOpt) { [weak self] in
            guard let self = self else { return }
            if let prev = self.manager.previousProfile(),
               self.manager.listProfiles().contains(prev) {
                self.performSwitch(to: prev)
            } else {
                NSSound.beep()
            }
        }
        if flipToken == nil { failedSlots.append("⌘⌥`") }

        // If the OS refused any binding (usually another app already owns the
        // combo), tell the user once per launch — registerHotkeys re-runs on
        // every profile change, so we don't want to nag.
        if !failedSlots.isEmpty, !didWarnHotkeyFailure {
            didWarnHotkeyFailure = true
            Dialogs.notify(
                title: "Some Swivel shortcuts are unavailable",
                body: "macOS wouldn't register \(failedSlots.joined(separator: ", ")) — another app may already use it. You can still switch from the menu bar."
            )
        }
    }

    /// Shared switch path used by both menu clicks and hotkeys. Pre-flight
    /// confirmations run synchronously on the main thread; the actual swap
    /// is handed to `SwitchCoordinator`, which serializes against concurrent
    /// invocations (hotkey spam / rapid clicks) and runs the heavy work on
    /// a background queue so the UI thread stays responsive.
    private func performSwitch(to name: String) {
        switcher.performSwitch(
            to: name,
            preflight: {
                if self.manager.activeProfile() == nil {
                    let confirm = Dialogs.confirm(
                        title: "No active account set",
                        message: "The current Claude session hasn't been saved. If you switch now, the session will be lost. Save it first using \"Add Account…\"."
                    )
                    if !confirm { return false }
                }
                if self.activityMonitor.likelyInUse() {
                    let confirm = Dialogs.confirm(
                        title: "Discard anything you're typing?",
                        message: "You're switching to \(name). Claude will quit and relaunch — any unsent message in the chat will be lost.",
                        confirmTitle: "Switch to \(name)"
                    )
                    if !confirm { return false }
                }
                return true
            },
            onStart: { [weak self] in
                // Hotkey-triggered switches can start while the popover
                // is open; close it so progress feedback (dimmed icon,
                // notification) isn't hidden behind a stale panel.
                self?.statusItemController?.closePopover()
                self?.setSwitchingUI(target: name)
            },
            onProgress: { [weak self] status in
                self?.statusItem.button?.toolTip = status
            },
            onSuccess: { [weak self] in
                guard let self = self else { return }
                self.clearSwitchingUI()
                self.refreshUI()
                Dialogs.notify(title: "Switched to \(name)", body: "Claude is relaunching.")
            },
            onFailure: { [weak self] error in
                guard let self = self else { return }
                self.clearSwitchingUI()
                Dialogs.alert("Switch failed", style: .critical, detail: error.localizedDescription)
            }
        )
    }

    /// Dim the menu bar icon to ~45% opacity and update the tooltip
    /// while a switch is in progress, so the user gets visible feedback
    /// that the app is working (the menu is closed so a progress line
    /// inside the menu wouldn't help).
    private func setSwitchingUI(target: String) {
        guard let button = statusItem.button else { return }
        let base = currentStatusIcon()
        let dimmed = NSImage(size: base.size)
        dimmed.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 0.4)
        dimmed.unlockFocus()
        button.image = dimmed
        button.toolTip = "Switching to \(target)…"
    }

    private func clearSwitchingUI() {
        statusItem.button?.image = currentStatusIcon()
        refreshTitle()
    }

    /// Build the icon using the active profile's color as background and
    /// Claude's service status as the ray color. Called anywhere we want
    /// the latest image.
    private func currentStatusIcon() -> NSImage {
        let bg: NSColor = {
            if let active = manager.activeProfile(),
               let hex = manager.profileColorHex(for: active),
               let color = NSColor(hexString: hex) {
                return color
            }
            return .systemGray
        }()
        // Active account's usage — drives the top-edge progress bar
        // on the icon when the account is nearing a limit. Stays
        // absent in healthy state (empty icon is the "all fine"
        // signal) so the icon doesn't ship noise.
        let activeUsage: UsageSnapshot? = {
            guard manager.activeProfile() != nil else { return nil }
            return ProfileUsageReader.read(claudeDir: manager.liveClaudeDir)
        }()
        return StatusIconRenderer.make(
            backgroundColor: bg,
            claudeStatus: statusChecker.latest?.level,
            usage: activeUsage
        )
    }

    // MARK: - Status pulse
    //
    // When Claude's service status is anything other than "operational",
    // slowly pulse the whole menu bar icon's opacity. Motion breaks
    // through any color-on-color camouflage and reads at a glance —
    // useful when the profile color happens to share a hue with the
    // status-ray color (most of the current palette does). The pulse
    // is intentionally slow (~1.3s full cycle) and shallow (only down
    // to 55% opacity) so it reads as "heads up" rather than urgent.

    private static let pulseAnimationKey = "swivel.statusPulse"

    /// Start or stop the pulse based on the latest status snapshot.
    /// No-op if the already-running state matches the desired state.
    private func updateStatusPulse(for level: ClaudeStatusLevel?) {
        let shouldPulse: Bool = {
            switch level {
            case .minor?, .major?, .critical?, .maintenance?: return true
            default: return false
            }
        }()
        if shouldPulse {
            startStatusPulse()
        } else {
            stopStatusPulse()
        }
    }

    private func startStatusPulse() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        if button.layer?.animation(forKey: Self.pulseAnimationKey) != nil {
            return  // already pulsing
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.55
        anim.duration = 1.3
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(anim, forKey: Self.pulseAnimationKey)
    }

    private func stopStatusPulse() {
        statusItem.button?.layer?.removeAnimation(forKey: Self.pulseAnimationKey)
    }

    /// Keep the menu bar item compact — just the icon, no text. The profile
    /// color in the icon already identifies which account is active; the
    /// name lives in the tooltip and the menu itself.
    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        button.title = ""
        if let name = manager.activeProfile() {
            button.toolTip = "Swivel — active: \(name)"
        } else {
            button.toolTip = "Swivel — no account selected"
        }
    }

    /// Refresh everything the user can see: tooltip, menu bar icon, and
    /// the view model feeding the popover + widget. Direct successor to
    /// the old `rebuildMenu()` — called from the same sites.
    private func refreshUI() {
        refreshTitle()
        statusItem.button?.image = currentStatusIcon()
        viewModel.refresh()
    }

    // MARK: - UI intents

    /// Bundle the SwiftUI surfaces' intents onto the existing handlers.
    /// Every closure closes the popover first: the handlers present
    /// modal NSAlerts, which would steal key status from the transient
    /// popover and dismiss it mid-interaction anyway — closing up front
    /// makes that deterministic.
    private func makeUIActions() -> UIActions {
        var actions = UIActions()
        let closing: (@escaping () -> Void) -> () -> Void = { [weak self] body in
            return {
                self?.statusItemController?.closePopover()
                body()
            }
        }
        actions.switchTo = { [weak self] name in
            self?.statusItemController?.closePopover()
            self?.performSwitch(to: name)
        }
        actions.flip = closing { [weak self] in self?.handleFlip() }
        actions.addAccount = closing { [weak self] in self?.handleAddAccount() }
        actions.updateCurrent = closing { [weak self] in self?.handleUpdateCurrent() }
        actions.rename = { [weak self] name in
            self?.statusItemController?.closePopover()
            self?.renameProfile(name)
        }
        actions.delete = { [weak self] name in
            self?.statusItemController?.closePopover()
            self?.deleteProfile(name)
        }
        actions.restoreBackup = { [weak self] profile, backupDirName in
            self?.statusItemController?.closePopover()
            self?.restoreBackup(profile: profile, backupDirName: backupDirName)
        }
        actions.setColor = { [weak self] profile, hex in
            // No modal involved — keep the popover open so the user
            // sees the swatch change in place.
            self?.setProfileColor(profile: profile, hex: hex)
        }
        actions.toggleLoginItem = closing { [weak self] in self?.handleToggleLoginItem() }
        actions.toggleWidget = { [weak self] in self?.widgetController?.toggle() }
        actions.toggleLiveUsage = { [weak self] in self?.handleToggleLiveUsage() }
        actions.openStatusPage = { [weak self] in self?.handleOpenStatusPage() }
        actions.about = closing { [weak self] in self?.handleAbout() }
        actions.help = { [weak self] in self?.handleOpenHelp() }
        actions.checkForUpdates = closing { [weak self] in self?.handleCheckForUpdates() }
        actions.quit = { NSApp.terminate(nil) }
        return actions
    }

    /// Minimal right-click menu — discoverability for menu-bar users
    /// and a guaranteed Quit path independent of SwiftUI.
    private func makeFallbackMenu() -> NSMenu {
        let menu = NSMenu()
        let about = NSMenuItem(title: "About Swivel", action: #selector(handleAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(handleCheckForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    // MARK: - Actions
    //
    // Invoked through the UIActions closure bundle (popover + widget)
    // and, for About / Check for Updates, the right-click fallback
    // NSMenu's selectors. Bodies unchanged from the NSMenu era — the
    // dialogs, alerts, and coordinator calls are the stable core the
    // SwiftUI surfaces delegate to.

    @objc func handleFlip() {
        guard let prev = manager.previousProfile(),
              manager.listProfiles().contains(prev) else { return }
        performSwitch(to: prev)
    }

    @objc func handleAddAccount() {
        guard let name = Dialogs.prompt(
            title: "Add Account",
            message: "Name this account (for example \"Personal\" or \"Work\"):",
            actionTitle: "Add"
        ) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if manager.listProfiles().contains(trimmed) {
            if !Dialogs.confirm(
                title: "Overwrite \(trimmed)?",
                message: "An account named \"\(trimmed)\" already exists. Overwriting replaces its saved session.",
                confirmTitle: "Overwrite"
            ) { return }
        }
        do {
            try manager.saveCurrent(as: trimmed)
            // Auto-assign the next unused preset color so new accounts show
            // up with a distinct identity immediately, without forcing the
            // user to navigate a submenu.
            if manager.profileColorHex(for: trimmed) == nil {
                let used = manager.assignedColorHexes()
                let pick = MenuStyle.colorPresets.first { !used.contains($0.hex.uppercased()) }
                    ?? MenuStyle.colorPresets.first
                if let hex = pick?.hex {
                    try? manager.setProfileColorHex(hex, for: trimmed)
                }
            }
            statusItem.button?.image = currentStatusIcon()
            refreshUI()
            registerHotkeys()
            Dialogs.notify(title: "Added \(trimmed)", body: "Current Claude session saved.")
        } catch {
            Dialogs.alert("Couldn't add account", style: .critical, detail: error.localizedDescription)
        }
    }

    @objc func handleUpdateCurrent() {
        guard let active = manager.activeProfile() else {
            Dialogs.alert("No active account", style: .informational,
                  detail: "Switch to an account first, then update it from Claude's current state.")
            return
        }
        do {
            try manager.updateCurrent()
            refreshUI()
            Dialogs.notify(title: "Updated \(active)", body: "Saved snapshot refreshed.")
        } catch {
            Dialogs.alert("Update failed", style: .critical, detail: error.localizedDescription)
        }
    }

    func renameProfile(_ oldName: String) {
        guard let newName = Dialogs.prompt(
            title: "Rename \(oldName)",
            message: "Enter a new name for this account.",
            actionTitle: "Rename",
            initialValue: oldName
        ) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        do {
            try manager.rename(profile: oldName, to: trimmed)
            statusItem.button?.image = currentStatusIcon()
            refreshUI()
            registerHotkeys()
            Dialogs.notify(title: "Renamed", body: "\(oldName) → \(trimmed)")
        } catch {
            Dialogs.alert("Rename failed", style: .warning, detail: error.localizedDescription)
        }
    }

    func deleteProfile(_ name: String) {
        let backupCount = manager.listBackups(for: name).count
        let backupClause = backupCount > 0
            ? " Plus \(backupCount) saved backup\(backupCount == 1 ? "" : "s") of this account will be removed."
            : ""
        if !Dialogs.confirm(
            title: "Delete \(name)?",
            message: "This removes the saved session. Cannot be undone.\(backupClause)",
            confirmTitle: "Delete"
        ) { return }
        do {
            try manager.delete(profile: name)
            statusItem.button?.image = currentStatusIcon()
            refreshUI()
            registerHotkeys()
        } catch {
            Dialogs.alert("Delete failed", style: .critical, detail: error.localizedDescription)
        }
    }

    func restoreBackup(profile: String, backupDirName backupName: String) {
        let backups = manager.listBackups(for: profile)
        guard let backup = backups.first(where: { $0.directoryName == backupName }) else {
            Dialogs.alert("Backup not found", style: .warning)
            return
        }
        let label = UsageFormatting.relativeTimeLabel(for: backup.date)
        if !Dialogs.confirm(
            title: "Restore \(profile) to \(label)?",
            message: "This replaces \(profile)'s current saved snapshot with the selected backup. The current snapshot becomes a new backup, so you can undo the undo."
        ) { return }
        // Quitting Claude + waiting is a blocking, multi-second operation; run
        // it (and the restore) off the main thread so the UI doesn't hang.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let outcome: Result<Void, Error>
            do {
                ClaudeAppController.quit()
                _ = ClaudeAppController.waitUntilQuit(timeout: 10)
                try self.manager.restoreBackup(backup, profile: profile)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                switch outcome {
                case .success:
                    self.refreshUI()
                    Dialogs.notify(title: "Restored \(profile)", body: "Snapshot rewound to \(label).")
                case .failure(let error):
                    Dialogs.alert("Restore failed", style: .critical, detail: error.localizedDescription)
                }
            }
        }
    }

    func setProfileColor(profile: String, hex: String?) {
        do {
            try manager.setProfileColorHex(hex, for: profile)
            // Only refresh the icon if the changed profile is currently active.
            if profile == manager.activeProfile() {
                statusItem.button?.image = currentStatusIcon()
            }
            refreshUI()
        } catch {
            Dialogs.alert("Couldn't save color", style: .warning, detail: error.localizedDescription)
        }
    }

    /// Toggle the live-usage opt-in. Enabling makes authenticated network
    /// requests to claude.ai, so the first time through we spell out exactly
    /// what that means and require an explicit confirm. Disabling is silent.
    func handleToggleLiveUsage() {
        if viewModel.liveUsageEnabled {
            viewModel.setLiveUsage(false)
            return
        }
        let confirmed = Dialogs.confirm(
            title: "Show live usage from claude.ai? (Experimental)",
            message: """
            To show real-time usage for each account, Swivel will make read-only \
            requests to claude.ai using each account's saved session — the same \
            data the Claude website shows on its usage page.

            This is an experimental feature and the only one that sends anything \
            off your Mac. It relies on undocumented claude.ai endpoints, so it may \
            break without notice. It stays off until you turn it on, you can turn \
            it back off any time, and only your own accounts are queried.
            """,
            confirmTitle: "Turn On"
        )
        if confirmed {
            viewModel.setLiveUsage(true)
            Dialogs.notify(title: "Live usage on", body: "Usage now refreshes from claude.ai.")
        }
    }

    @objc func handleToggleLoginItem() {
        let (enabled, err) = LoginItemManager.toggle()
        if let err = err {
            Dialogs.alert(
                "Couldn't change login item",
                style: .warning,
                detail: "\(err.localizedDescription)\n\nIf Swivel is being run from the build folder rather than /Applications, this can fail. Try `./build-app.sh --install` first."
            )
        } else {
            Dialogs.notify(
                title: enabled ? "Launch at login enabled" : "Launch at login disabled",
                body: enabled ? "Swivel will start automatically on next boot." : ""
            )
        }
        refreshUI()
    }

    @objc func handleAbout() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"

        let a = NSAlert()
        a.messageText = "Swivel \(version) (build \(build))"
        a.informativeText = """
        Switch between Claude Desktop accounts without logging out.

        Shortcuts
          ⌘⌥1 … ⌘⌥9    Switch to an account by slot
          ⌘⌥ `         Flip back to the previous account

        Backups
          Each account keeps its last 3 snapshots. Restore one from
          an account row's "…" menu ▸ Restore Backup.

        Privacy
          Everything stays on this Mac. No telemetry. By default the
          only network request is to the public Claude status page.
          The optional Live Usage feature (off by default) additionally
          queries claude.ai with each account's own session.

        Unofficial tool. Not affiliated with Anthropic.
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "View on GitHub")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn {
            if let url = URL(string: Self.helpURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func handleOpenStatusPage() {
        if let url = URL(string: "https://status.claude.com") {
            NSWorkspace.shared.open(url)
        }
        // Nudge an immediate re-check in case the user noticed an issue and
        // wants the menu state to refresh without waiting for the next poll.
        statusChecker.checkNow()
    }

    @objc func handleOpenHelp() {
        // Project README on GitHub — the canonical entry point for docs,
        // troubleshooting, and bug reports.
        if let url = URL(string: Self.helpURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func handleCheckForUpdates() {
        // Forwards to Sparkle's standard updater UI. It'll fetch the
        // appcast, compare versions, and either tell the user they're
        // up to date or offer the new build.
        updaterController.checkForUpdates(nil)
    }

    /// Canonical project URL. Surfaced via the Help menu and the About
    /// dialog. Update this when the repository moves.
    static let helpURL = "https://github.com/jspanji/Swivel"

}
