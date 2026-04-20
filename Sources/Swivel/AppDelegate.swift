import AppKit
import Carbon.HIToolbox
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let manager = ProfileManager()
    private let statusChecker = ClaudeStatusChecker()
    private let hotkeys = HotkeyManager()
    private lazy var switcher = SwitchCoordinator(manager: manager)
    private lazy var menuBuilder = MenuBuilder(
        target: self,
        actions: MenuBuilder.Actions(
            switchAccount: #selector(handleSwitch(_:)),
            flip: #selector(handleFlip),
            addAccount: #selector(handleAddAccount),
            updateCurrent: #selector(handleUpdateCurrent),
            rename: #selector(handleRename(_:)),
            delete: #selector(handleDelete(_:)),
            restoreBackup: #selector(handleRestoreBackup(_:)),
            setProfileColor: #selector(handleSetProfileColor(_:)),
            toggleLoginItem: #selector(handleToggleLoginItem),
            openStatusPage: #selector(handleOpenStatusPage),
            about: #selector(handleAbout),
            openHelp: #selector(handleOpenHelp)
        ),
        manager: manager,
        statusChecker: statusChecker,
        menuDelegate: self
    )

    // Timestamp of the most recent moment Claude.app was observed to be
    // the frontmost application. Updated both by didActivateApplication
    // notifications (catches the transition) and by a 1-second polling
    // timer (catches "user has been in Claude continuously"). Nil until
    // we observe it at least once.
    private var claudeLastFrontmostAt: Date?
    private let claudeBundleID = "com.anthropic.claudefordesktop"
    private let claudeInUseWindow: TimeInterval = 5
    private var claudePollTimer: Timer?

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
        rebuildMenu()

        // Start polling Anthropic's public status page. On each update:
        //   1. redraw the menu bar icon (status ray color changes),
        //   2. rebuild the menu (textual status line + usage data),
        //   3. start/stop the attention pulse based on the new level.
        statusChecker.onUpdate = { [weak self] snapshot in
            guard let self = self else { return }
            self.statusItem.button?.image = self.currentStatusIcon()
            self.rebuildMenu()
            self.updateStatusPulse(for: snapshot.level)
        }
        statusChecker.start()

        registerHotkeys()
        observeClaudeFrontmost()

        // Ask once for permission to post "Switched to…" banners. Denial
        // is fine — `notify()` silently no-ops if the system rejects
        // the request. The prompt appears on first launch only.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    /// Keep `claudeLastFrontmostAt` reasonably fresh while the user is
    /// actually using Claude. Using only activation notifications missed
    /// the common case of "user has been typing in Claude for 10 minutes"
    /// — the last activation event was 10 minutes ago, so the heuristic
    /// would say Claude wasn't recently in use. The 1s polling timer
    /// fixes that by refreshing the timestamp on every tick while Claude
    /// remains frontmost.
    private func observeClaudeFrontmost() {
        refreshClaudeFrontmost()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == self.claudeBundleID
            else { return }
            self.claudeLastFrontmostAt = Date()
        }
        claudePollTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            self?.refreshClaudeFrontmost()
        }
    }

    private func refreshClaudeFrontmost() {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID {
            claudeLastFrontmostAt = Date()
        }
    }

    /// Best-effort check: has the user been actively in Claude right
    /// before this switch? If so, a draft message may be on screen and
    /// about to be discarded when Claude relaunches.
    ///
    /// Signal:
    ///   - Claude is currently the frontmost application, OR
    ///   - Claude was frontmost within the last `claudeInUseWindow` seconds.
    ///
    /// The polling timer keeps the timestamp fresh during continuous use,
    /// which fixes the "typed for 10 minutes" false negative.
    private func claudeLikelyInUse() -> Bool {
        guard ClaudeAppController.isRunning() else { return false }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID {
            return true
        }
        if let last = claudeLastFrontmostAt,
           Date().timeIntervalSince(last) < claudeInUseWindow {
            return true
        }
        return false
    }

    // MARK: - Global hotkeys

    /// Bind ⌘⌥1..9 to profiles in alphabetical order, and ⌘⌥` to flip
    /// between the current and previously-active profiles. Re-run whenever
    /// the profile list might have changed (save / delete).
    private func registerHotkeys() {
        hotkeys.unregisterAll()

        // Per-profile number hotkeys.
        let profiles = manager.listProfiles()
        for (idx, profile) in profiles.prefix(numberKeyCodes.count).enumerated() {
            let keyCode = numberKeyCodes[idx]
            hotkeys.register(keyCode: keyCode, modifiers: cmdOpt) { [weak self] in
                self?.performSwitch(to: profile)
            }
        }

        // Flip-to-previous hotkey (⌘⌥`).
        hotkeys.register(keyCode: kVK_ANSI_Grave, modifiers: cmdOpt) { [weak self] in
            guard let self = self else { return }
            if let prev = self.manager.previousProfile(),
               self.manager.listProfiles().contains(prev) {
                self.performSwitch(to: prev)
            } else {
                NSSound.beep()
            }
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
                    let confirm = self.confirmAlert(
                        title: "No active account set",
                        message: "The current Claude session hasn't been saved. If you switch now, the session will be lost. Save it first using \"Add Account…\"."
                    )
                    if !confirm { return false }
                }
                if self.claudeLikelyInUse() {
                    let confirm = self.confirmAlert(
                        title: "Discard anything you're typing?",
                        message: "You're switching to \(name). Claude will quit and relaunch — any unsent message in the chat will be lost.",
                        confirmTitle: "Switch to \(name)"
                    )
                    if !confirm { return false }
                }
                return true
            },
            onStart: { [weak self] in
                self?.setSwitchingUI(target: name)
            },
            onProgress: { [weak self] status in
                self?.statusItem.button?.toolTip = status
            },
            onSuccess: { [weak self] in
                guard let self = self else { return }
                self.clearSwitchingUI()
                self.rebuildMenu()
                self.notify(title: "Switched to \(name)", body: "Claude is relaunching.")
            },
            onFailure: { [weak self] error in
                guard let self = self else { return }
                self.clearSwitchingUI()
                self.alert("Switch failed", style: .critical, detail: error.localizedDescription)
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
        return Self.makeStatusIcon(
            backgroundColor: bg,
            claudeStatus: statusChecker.latest?.level,
            usage: activeUsage
        )
    }

    /// Claude-style menu bar icon:
    ///   - Rounded square background in the active profile's color.
    ///   - 10-ray starburst on top, colored by Claude's service status.
    ///   - Thin progress bar along the TOP edge, filled to the active
    ///     account's utilization when approaching/over the rate limit.
    ///     Absent (no bar drawn) in healthy state — empty top = all fine.
    ///   - Arrow-switch badge in the bottom-right.
    ///
    /// Three independent signals, each in its own visual real estate:
    ///   profile color = "which account am I on"
    ///   ray color     = "is Claude's service OK"
    ///   top bar       = "am I about to hit my personal rate limit"
    private static func makeStatusIcon(
        backgroundColor: NSColor,
        claudeStatus: ClaudeStatusLevel?,
        usage: UsageSnapshot? = nil
    ) -> NSImage {
        let canvas: CGFloat = 22
        let totalSize = NSSize(width: canvas, height: canvas)

        // Badge geometry: subtle indicator tucked into the bottom-right.
        let badgeSize: CGFloat = 6.5
        let badgeRect = NSRect(
            x: canvas - badgeSize,
            y: 0,
            width: badgeSize,
            height: badgeSize
        )

        let composite = NSImage(size: totalSize)
        composite.lockFocus()

        // 1. Rounded card in the profile color.
        let bgRect = NSRect(origin: .zero, size: totalSize).insetBy(dx: 1, dy: 1)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 5, yRadius: 5)
        backgroundColor.setFill()
        bgPath.fill()

        // 2. White multi-ray starburst centered in the card. Drawn from
        //    primitives so we can pick the ray count exactly; SF Symbols'
        //    `asterisk` is capped at 6 points which reads too sparse.
        let rayCount = 10
        let innerRadius: CGFloat = 1.0   // tiny center gap
        let outerRadius: CGFloat = 7.5
        let center = NSPoint(x: canvas / 2, y: canvas / 2)

        // Rays are drawn in two passes: a halo first (so the rays stay
        // legible if the profile color and status color happen to
        // share a hue — e.g. a green profile with "operational" green
        // rays), then the main status color on top.
        let rays = NSBezierPath()
        rays.lineCapStyle = .round
        for i in 0..<rayCount {
            let angle = (CGFloat.pi * 2 / CGFloat(rayCount)) * CGFloat(i)
            let from = NSPoint(
                x: center.x + innerRadius * cos(angle),
                y: center.y + innerRadius * sin(angle)
            )
            let to = NSPoint(
                x: center.x + outerRadius * cos(angle),
                y: center.y + outerRadius * sin(angle)
            )
            rays.move(to: from)
            rays.line(to: to)
        }

        // Halo pass — adaptive to profile luminance. A black halo on a
        // dark profile is invisible (the old bug); every color in the
        // current palette lands below 0.35 luminance, so in practice
        // we always draw a white halo today. The branch is there so
        // a lighter custom profile (future feature) still gets the
        // right treatment.
        let profileLum = Self.relativeLuminance(of: backgroundColor)
        let haloColor: NSColor = profileLum >= 0.5
            ? NSColor.black.withAlphaComponent(0.45)
            : NSColor.white.withAlphaComponent(0.55)
        haloColor.setStroke()
        rays.lineWidth = 2.5
        rays.stroke()

        // Main pass — status color.
        MenuStyle.statusRayColor(for: claudeStatus).setStroke()
        rays.lineWidth = 1.5
        rays.stroke()

        // 2. Translucent white circle for the badge background. No border —
        //    the soft edge blends into the card rather than competing with
        //    the starburst for attention.
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        // 3. Top-edge usage progress bar — only drawn when the active
        //    account is approaching or over its rate limit. The bar
        //    runs across the top edge of the card, filled to the
        //    utilization fraction. Empty top edge = healthy, which is
        //    the signal-by-absence we want.
        drawUsageBar(usage: usage, cardRect: bgRect)

        // 4. Switch-arrow glyph — muted gray, centered in the badge.
        //    Its color no longer carries usage signal (the top bar
        //    does that now); it's pure function affordance.
        let arrowConfig = NSImage.SymbolConfiguration(pointSize: 3.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [
                NSColor.black.withAlphaComponent(0.6)
            ]))
        if let arrows = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "Switch"
        )?.withSymbolConfiguration(arrowConfig) {
            let g = arrows.size
            let drawRect = NSRect(
                x: badgeRect.midX - g.width / 2,
                y: badgeRect.midY - g.height / 2,
                width: g.width,
                height: g.height
            )
            arrows.draw(in: drawRect)
        }

        composite.unlockFocus()
        return composite
    }

    /// Draw the usage progress bar along the top edge of the icon card.
    /// Only runs when `usage` indicates a warning — the healthy path
    /// renders no bar, keeping the icon calm until there's something
    /// to flag. The bar has a subtle dark track under it so even a
    /// small fill reads against light profile colors.
    private static func drawUsageBar(usage: UsageSnapshot?, cardRect: NSRect) {
        guard let usage = usage,
              usage.status == .approachingLimit || usage.status == .limitReached,
              let utilization = usage.utilization
        else { return }

        let barHeight: CGFloat = 2.0
        // Inset 1pt from each side so the bar respects the card's
        // rounded corners visually (it sits inside the radius curve).
        let inset: CGFloat = 2.0
        let barY = cardRect.maxY - barHeight - 0.5
        let barTrack = NSRect(
            x: cardRect.minX + inset,
            y: barY,
            width: cardRect.width - 2 * inset,
            height: barHeight
        )

        // Dark track — gives the bar a definition edge so a thin fill
        // doesn't disappear against a warm profile color (orange/red
        // profile with systemOrange fill is the worst case).
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: barTrack).fill()

        // Fill: clamp + floor at 4% so "approaching_limit" just past
        // threshold still draws something visible.
        let clamped = max(0.04, min(1.0, utilization))
        let fillColor: NSColor = {
            switch usage.status {
            case .limitReached: return .systemRed
            case .approachingLimit:
                return clamped >= 0.9 ? .systemRed : .systemOrange
            default: return .systemOrange
            }
        }()
        let fillRect = NSRect(
            x: barTrack.minX,
            y: barTrack.minY,
            width: barTrack.width * CGFloat(clamped),
            height: barTrack.height
        )
        fillColor.setFill()
        NSBezierPath(rect: fillRect).fill()
    }

    /// WCAG-style relative luminance of a color in sRGB. Used to
    /// decide whether to place light- or dark-tinted chrome on top of
    /// a given profile background (e.g. the ray halo).
    private static func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.redComponent)
            + 0.7152 * lin(rgb.greenComponent)
            + 0.0722 * lin(rgb.blueComponent)
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

    private func rebuildMenu() {
        refreshTitle()
        statusItem.menu = menuBuilder.build()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Throttled inside ClaudeStatusChecker — spam-safe.
        statusChecker.checkNow()
    }

    // MARK: - Actions
    //
    // These are `@objc` (internal) rather than `@objc private` so MenuBuilder
    // can pass their selectors via `#selector(...)` from outside this file.

    @objc func handleSwitch(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        performSwitch(to: name)
    }

    @objc func handleFlip() {
        guard let prev = manager.previousProfile(),
              manager.listProfiles().contains(prev) else { return }
        performSwitch(to: prev)
    }

    @objc func handleAddAccount() {
        guard let name = promptString(
            title: "Add Account",
            message: "Name this account (for example \"Personal\" or \"Work\"):",
            actionTitle: "Add"
        ) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if manager.listProfiles().contains(trimmed) {
            if !confirmAlert(
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
            rebuildMenu()
            registerHotkeys()
            notify(title: "Added \(trimmed)", body: "Current Claude session saved.")
        } catch {
            alert("Couldn't add account", style: .critical, detail: error.localizedDescription)
        }
    }

    @objc func handleUpdateCurrent() {
        guard let active = manager.activeProfile() else {
            alert("No active account", style: .informational,
                  detail: "Switch to an account first, then update it from Claude's current state.")
            return
        }
        do {
            try manager.updateCurrent()
            rebuildMenu()
            notify(title: "Updated \(active)", body: "Saved snapshot refreshed.")
        } catch {
            alert("Update failed", style: .critical, detail: error.localizedDescription)
        }
    }

    @objc func handleRename(_ sender: NSMenuItem) {
        guard let oldName = sender.representedObject as? String else { return }
        guard let newName = promptString(
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
            rebuildMenu()
            registerHotkeys()
            notify(title: "Renamed", body: "\(oldName) → \(trimmed)")
        } catch {
            alert("Rename failed", style: .warning, detail: error.localizedDescription)
        }
    }

    @objc func handleDelete(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let backupCount = manager.listBackups(for: name).count
        let backupClause = backupCount > 0
            ? " Plus \(backupCount) saved backup\(backupCount == 1 ? "" : "s") of this account will be removed."
            : ""
        if !confirmAlert(
            title: "Delete \(name)?",
            message: "This removes the saved session. Cannot be undone.\(backupClause)",
            confirmTitle: "Delete"
        ) { return }
        do {
            try manager.delete(profile: name)
            statusItem.button?.image = currentStatusIcon()
            rebuildMenu()
            registerHotkeys()
        } catch {
            alert("Delete failed", style: .critical, detail: error.localizedDescription)
        }
    }

    @objc func handleRestoreBackup(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let profile = payload["profile"],
              let backupName = payload["backup"] else { return }
        let backups = manager.listBackups(for: profile)
        guard let backup = backups.first(where: { $0.directoryName == backupName }) else {
            alert("Backup not found", style: .warning)
            return
        }
        let label = MenuBuilder.relativeTimeLabel(for: backup.date)
        if !confirmAlert(
            title: "Restore \(profile) to \(label)?",
            message: "This replaces \(profile)'s current saved snapshot with the selected backup. The current snapshot becomes a new backup, so you can undo the undo."
        ) { return }
        do {
            ClaudeAppController.quit()
            _ = ClaudeAppController.waitUntilQuit(timeout: 10)
            try manager.restoreBackup(backup, profile: profile)
            rebuildMenu()
            notify(title: "Restored \(profile)", body: "Snapshot rewound to \(label).")
        } catch {
            alert("Restore failed", style: .critical, detail: error.localizedDescription)
        }
    }

    @objc func handleSetProfileColor(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let profile = payload["profile"] else { return }
        let hex = payload["hex"] ?? ""
        do {
            try manager.setProfileColorHex(hex.isEmpty ? nil : hex, for: profile)
            // Only refresh the icon if the changed profile is currently active.
            if profile == manager.activeProfile() {
                statusItem.button?.image = currentStatusIcon()
            }
            rebuildMenu()
        } catch {
            alert("Couldn't save color", style: .warning, detail: error.localizedDescription)
        }
    }

    @objc func handleToggleLoginItem() {
        let (enabled, err) = LoginItemManager.toggle()
        if let err = err {
            alert(
                "Couldn't change login item",
                style: .warning,
                detail: "\(err.localizedDescription)\n\nIf Swivel is being run from the build folder rather than /Applications, this can fail. Try `./build-app.sh --install` first."
            )
        } else {
            notify(
                title: enabled ? "Launch at login enabled" : "Launch at login disabled",
                body: enabled ? "Swivel will start automatically on next boot." : ""
            )
        }
        rebuildMenu()
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
          Manage ▸ <Account> ▸ Restore Backup.

        Privacy
          Everything stays on this Mac. No telemetry. The only network
          request is to the public Claude status page for the menu bar
          service-status indicator.

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

    /// Canonical project URL. Surfaced via the Help menu and the About
    /// dialog. Update this when the repository moves.
    static let helpURL = "https://github.com/jspanji/Swivel"

    // MARK: - UI helpers

    private func alert(_ title: String, style: NSAlert.Style, detail: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func confirmAlert(
        title: String,
        message: String,
        confirmTitle: String = "Continue"
    ) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: confirmTitle)
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    private func promptString(
        title: String,
        message: String,
        actionTitle: String = "Save",
        initialValue: String = ""
    ) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: actionTitle)
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initialValue
        a.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        // Focus the field and select its contents so pressing Return
        // commits the edit and typing replaces the initial value.
        DispatchQueue.main.async { field.selectText(nil) }
        let response = a.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Post a banner notification via UserNotifications.framework. Silently
    /// no-ops if the user denied permission or we're running outside a
    /// signed/bundled context (unit test, `swift run`) where the OS refuses
    /// delivery. The identifier is a fresh UUID so consecutive banners
    /// stack rather than replace each other.
    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil      // deliver immediately
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
