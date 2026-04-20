import AppKit

/// One named color choice offered in the "Profile Color" menu. `hex` is
/// what we persist (stable across OS appearance changes — system colors
/// would resolve differently under macOS accent/appearance overrides).
struct ColorPreset {
    let name: String
    let hex: String
}

/// Palette + small rendering utilities shared by the menu (swatches) and
/// the menu bar icon (ray color). Lives with the menu because the palette
/// is primarily a menu concern; the icon code just reaches in for the
/// status-ray lookup.
enum MenuStyle {
    /// Profile color palette. "Identity" colors — sophisticated and
    /// curated, ~60% saturation. Deliberately muted so the bright
    /// status rays drawn on top have clear visual hierarchy. Each hue
    /// is well-separated from its neighbors on the color wheel, so 10
    /// profiles remain distinguishable at 22-point menu bar size.
    static let colorPresets: [ColorPreset] = [
        ColorPreset(name: "Red",     hex: "#BE3A3A"),   // warm brick red
        ColorPreset(name: "Orange",  hex: "#D97757"),   // Claude brand coral
        ColorPreset(name: "Amber",   hex: "#C68A2B"),   // warm gold
        ColorPreset(name: "Green",   hex: "#4A8659"),   // forest / sage
        ColorPreset(name: "Teal",    hex: "#2D8B89"),   // deep teal
        ColorPreset(name: "Blue",    hex: "#3559A1"),   // confident cobalt
        ColorPreset(name: "Indigo",  hex: "#5050A8"),   // indigo
        ColorPreset(name: "Purple",  hex: "#7246B0"),   // rich plum
        ColorPreset(name: "Pink",    hex: "#B84381"),   // rose (not neon)
        ColorPreset(name: "Slate",   hex: "#5F6773")    // cool neutral gray
    ]

    /// Small 12×12 rounded colored square for use as a menu item leading
    /// icon. Shared by profile swatches, preset swatches, and status
    /// swatch. Outline uses the dynamic `separatorColor` so the edge
    /// reads correctly in both light and dark menu appearances — a
    /// fixed black outline (the previous behaviour) disappeared in
    /// dark mode.
    static func colorSwatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25),
            xRadius: 3, yRadius: 3
        )
        border.lineWidth = 0.5
        border.stroke()
        img.unlockFocus()
        return img
    }

    /// Convenience — look up a preset by hex and render its swatch.
    static func colorSwatch(hex: String) -> NSImage? {
        guard let color = NSColor(hexString: hex) else { return nil }
        return colorSwatch(color)
    }

    /// Status ray colors. These are "alert" colors — punchy, saturated,
    /// universally-recognized (Tailwind-500-ish). Brighter and more
    /// saturated than the profile palette so status reads as distinct
    /// signal *over* the profile-color background.
    ///
    /// Red covers both `major` and `critical` — orange is too easy to
    /// confuse with yellow at menu bar size. Loading/unknown is white
    /// for maximum contrast against any profile color.
    static func statusRayColor(for level: ClaudeStatusLevel?) -> NSColor {
        guard let level = level else { return .white }
        let hex: String
        switch level {
        case .none:        hex = "#22C55E"   // emerald — operational
        case .minor:       hex = "#F59E0B"   // amber — warning
        case .major:       hex = "#EF4444"   // red — alert
        case .critical:    hex = "#EF4444"   // red — same visual weight
        case .maintenance: hex = "#3B82F6"   // cobalt — info
        case .unknown:     return .white
        }
        return NSColor(hexString: hex) ?? .white
    }
}

/// Builds the status-bar menu from the current profile state. Exists to
/// keep AppDelegate out of the business of menu item composition — menu
/// structure is declarative enough that it's worth separating from the
/// imperative lifecycle + action-handling code.
///
/// Action selectors are passed in via `Actions` rather than referenced
/// directly, so MenuBuilder has no compile-time dependency on
/// AppDelegate's handler names. The `target` is kept weak because
/// NSMenuItem does not retain its target.
final class MenuBuilder {
    struct Actions {
        let switchAccount: Selector
        let flip: Selector
        let addAccount: Selector
        let updateCurrent: Selector
        let rename: Selector
        let delete: Selector
        let restoreBackup: Selector
        let setProfileColor: Selector
        let toggleLoginItem: Selector
        let openStatusPage: Selector
        let about: Selector
        let openHelp: Selector
    }

    private weak var target: NSObject?
    private let actions: Actions
    private let manager: ProfileManager
    private let statusChecker: ClaudeStatusChecker
    private weak var menuDelegate: NSMenuDelegate?

    init(
        target: NSObject,
        actions: Actions,
        manager: ProfileManager,
        statusChecker: ClaudeStatusChecker,
        menuDelegate: NSMenuDelegate
    ) {
        self.target = target
        self.actions = actions
        self.manager = manager
        self.statusChecker = statusChecker
        self.menuDelegate = menuDelegate
    }

    // MARK: - Entry point

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let profiles = manager.listProfiles()
        let active = manager.activeProfile()
        let statusLevel = statusChecker.latest?.level

        // Prominent top-of-menu alert for Claude service issues. Hidden
        // when operational — no point dedicating a row to "all fine."
        if let level = statusLevel, level != .none, level != .unknown {
            addStatusAlert(to: menu, level: level)
            menu.addItem(.separator())
        }

        if profiles.isEmpty {
            addOnboarding(to: menu)
        } else {
            // Usage comparison sits above the account list so it's the
            // first thing the user sees on every open. It self-hides
            // when we have no snapshots, so this is a no-op pre-setup.
            addUsageHeader(to: menu, profiles: profiles, active: active)

            addAccountSection(to: menu, profiles: profiles, active: active)
            menu.addItem(.separator())
            addAccountActions(to: menu, profiles: profiles, active: active)
            menu.addItem(.separator())
        }

        // Settings: Launch at Login.
        if LoginItemManager.isAvailable {
            let loginItem = NSMenuItem(
                title: "Launch at Login",
                action: actions.toggleLoginItem,
                keyEquivalent: ""
            )
            loginItem.target = target
            loginItem.state = LoginItemManager.isEnabled ? .on : .off
            menu.addItem(loginItem)
        }
        menu.addItem(.separator())

        // Compact Claude status footer — quiet when operational; the big
        // alert at the top handles the degraded case.
        addStatusFooter(to: menu, level: statusLevel)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Swivel", action: actions.about, keyEquivalent: "")
        about.target = target
        menu.addItem(about)

        let help = NSMenuItem(title: "Help & Documentation", action: actions.openHelp, keyEquivalent: "")
        help.target = target
        menu.addItem(help)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Wire up the delegate so we can trigger a status re-check whenever
        // the user opens the menu — nearly-real-time without busy polling.
        menu.delegate = menuDelegate
        return menu
    }

    // MARK: - Sections

    /// First-run guidance when no accounts exist. Walks the user through
    /// what this app does and how to get started.
    private func addOnboarding(to menu: NSMenu) {
        let title = NSMenuItem(title: "Welcome to Swivel", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(
            string: "Welcome to Swivel",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        title.isEnabled = false
        menu.addItem(title)

        let desc = NSMenuItem(
            title: "Quickly switch between Claude accounts.",
            action: nil, keyEquivalent: ""
        )
        desc.isEnabled = false
        menu.addItem(desc)
        menu.addItem(.separator())

        let step1 = NSMenuItem(title: "1. Sign into your Claude account", action: nil, keyEquivalent: "")
        step1.isEnabled = false
        menu.addItem(step1)

        let step2 = NSMenuItem(
            title: "2. Save this session as an account…",
            action: actions.addAccount,
            keyEquivalent: "s"
        )
        step2.target = target
        menu.addItem(step2)

        let step3 = NSMenuItem(
            title: "3. Sign out, sign into another, save that too",
            action: nil, keyEquivalent: ""
        )
        step3.isEnabled = false
        menu.addItem(step3)

        let step4 = NSMenuItem(
            title: "Then: ⌘⌥1 / ⌘⌥2 to switch any time",
            action: nil, keyEquivalent: ""
        )
        step4.isEnabled = false
        menu.addItem(step4)
    }

    /// The core "which account?" section — account list + persistent
    /// last-used row. Active account is bolded for quick scanning.
    /// Usage state for each account now lives in the dedicated
    /// `UsageHeaderView` at the top of the menu, so rows here stay
    /// purely about identity + shortcut.
    private func addAccountSection(to menu: NSMenu, profiles: [String], active: String?) {
        let header = NSMenuItem(title: "Switch Account", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for (idx, name) in profiles.enumerated() {
            let item = NSMenuItem(title: name, action: actions.switchAccount, keyEquivalent: "")
            item.target = target
            item.representedObject = name
            item.image = profileSwatch(for: name)

            // Bold the active row; regular weight otherwise.
            let weight: NSFont = (name == active)
                ? .boldSystemFont(ofSize: NSFont.systemFontSize)
                : .menuFont(ofSize: NSFont.systemFontSize)
            item.attributedTitle = NSAttributedString(string: name, attributes: [.font: weight])

            // Usage detail (plan, remaining, reset, freshness) lives in
            // the UsageHeaderView above — no row tooltip needed.
            if name == active { item.state = .on }
            if idx < 9 {
                item.keyEquivalent = "\(idx + 1)"
                item.keyEquivalentModifierMask = [.command, .option]
            }
            menu.addItem(item)
        }

        // Persistent "Last used" flip row. Shown whenever a previous
        // account exists and is still valid — no longer hidden.
        if let prev = manager.previousProfile(), profiles.contains(prev), prev != active {
            let flip = NSMenuItem(
                title: "Last: \(prev)",
                action: actions.flip,
                keyEquivalent: "`"
            )
            flip.image = profileSwatch(for: prev)
            flip.keyEquivalentModifierMask = [.command, .option]
            flip.target = target
            menu.addItem(flip)
        }
    }

    /// Post-account-list actions: update-current, add-new, per-account
    /// Manage submenu. Update-current is disabled when there's no active.
    private func addAccountActions(to menu: NSMenu, profiles: [String], active: String?) {
        if let active = active {
            let update = NSMenuItem(
                title: "Update \(active)",
                action: actions.updateCurrent,
                keyEquivalent: ""
            )
            update.toolTip = "Refresh the saved snapshot of \(active) from the current Claude session."
            update.target = target
            menu.addItem(update)
        }

        let add = NSMenuItem(
            title: "Add Account…",
            action: actions.addAccount,
            keyEquivalent: "s"
        )
        add.target = target
        menu.addItem(add)

        // Consolidated per-account Manage submenu — Rename / Color /
        // Restore Backup / Delete all live under one profile entry.
        let manageParent = NSMenuItem(title: "Manage", action: nil, keyEquivalent: "")
        let manageMenu = NSMenu()
        for profile in profiles {
            let perProfile = NSMenu()

            // Rename…
            let rename = NSMenuItem(
                title: "Rename…",
                action: actions.rename,
                keyEquivalent: ""
            )
            rename.target = target
            rename.representedObject = profile
            perProfile.addItem(rename)

            // Change Color ▸
            perProfile.addItem(buildColorSubmenu(for: profile))

            // Restore Backup ▸ (if backups exist)
            let backups = manager.listBackups(for: profile)
            if !backups.isEmpty {
                let restoreParent = NSMenuItem(title: "Restore Backup", action: nil, keyEquivalent: "")
                let restoreMenu = NSMenu()
                for backup in backups {
                    let bi = NSMenuItem(
                        title: Self.relativeTimeLabel(for: backup.date),
                        action: actions.restoreBackup,
                        keyEquivalent: ""
                    )
                    bi.target = target
                    bi.representedObject = ["profile": profile, "backup": backup.directoryName]
                    restoreMenu.addItem(bi)
                }
                restoreParent.submenu = restoreMenu
                perProfile.addItem(restoreParent)
            }

            perProfile.addItem(.separator())

            let delete = NSMenuItem(
                title: "Delete…",
                action: actions.delete,
                keyEquivalent: ""
            )
            delete.target = target
            delete.representedObject = profile
            perProfile.addItem(delete)

            let profileEntry = NSMenuItem(title: profile, action: nil, keyEquivalent: "")
            profileEntry.image = profileSwatch(for: profile)
            profileEntry.submenu = perProfile
            manageMenu.addItem(profileEntry)
        }
        manageParent.submenu = manageMenu
        menu.addItem(manageParent)
    }

    /// Color picker submenu for a single account: "None" + each preset.
    private func buildColorSubmenu(for profile: String) -> NSMenuItem {
        let currentHex = manager.profileColorHex(for: profile)
        let submenu = NSMenu()

        let none = NSMenuItem(
            title: "None",
            action: actions.setProfileColor,
            keyEquivalent: ""
        )
        none.target = target
        none.representedObject = ["profile": profile, "hex": ""]
        if currentHex == nil { none.state = .on }
        submenu.addItem(none)
        submenu.addItem(.separator())

        for preset in MenuStyle.colorPresets {
            let item = NSMenuItem(
                title: preset.name,
                action: actions.setProfileColor,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = ["profile": profile, "hex": preset.hex]
            if let swatch = MenuStyle.colorSwatch(hex: preset.hex) { item.image = swatch }
            if currentHex?.uppercased() == preset.hex.uppercased() { item.state = .on }
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    /// Prominent top-of-menu alert for degraded Claude service. Bold,
    /// with a colored swatch. Click opens the status page.
    private func addStatusAlert(to menu: NSMenu, level: ClaudeStatusLevel) {
        let desc = statusChecker.latest?.description ?? level.rawValue.capitalized
        let title = NSMenuItem(
            title: desc,
            action: actions.openStatusPage,
            keyEquivalent: ""
        )
        title.target = target
        title.image = statusSwatch(for: level)
        title.attributedTitle = NSAttributedString(
            string: "Claude: \(desc)",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        menu.addItem(title)
    }

    /// Compact footer line for service status. Muted when operational —
    /// the menu bar rays already show it, so the menu line is there for
    /// confirmation + access to the status page.
    private func addStatusFooter(to menu: NSMenu, level: ClaudeStatusLevel?) {
        let footer = NSMenuItem(
            title: "",
            action: actions.openStatusPage,
            keyEquivalent: ""
        )
        footer.target = target
        footer.image = statusSwatch(for: level)

        let text: String
        if let level = level {
            switch level {
            case .none: text = "Claude service operational"
            case .minor, .major, .critical:
                text = "Claude: \(statusChecker.latest?.description ?? "Issue reported")"
            case .maintenance: text = "Claude: Maintenance in progress"
            case .unknown: text = "Claude: Status unavailable"
            }
        } else {
            text = "Checking Claude status…"
        }
        footer.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]
        )
        menu.addItem(footer)
    }

    // MARK: - Swatches + helpers

    /// Swatch for a profile's assigned color, or a muted "unset" swatch
    /// if none is configured. Always returns an image so menu alignment
    /// stays consistent across rows regardless of whether a profile has
    /// a color.
    private func profileSwatch(for profile: String) -> NSImage {
        if let hex = manager.profileColorHex(for: profile),
           let img = MenuStyle.colorSwatch(hex: hex) { return img }
        return MenuStyle.colorSwatch(.systemGray.withAlphaComponent(0.35))
    }

    /// Swatch that matches the status ray color, used next to the
    /// "Claude status:" line. Unknown/loading gets a neutral gray so
    /// the menu doesn't show a stark white square.
    private func statusSwatch(for level: ClaudeStatusLevel?) -> NSImage {
        guard let level = level else {
            return MenuStyle.colorSwatch(.systemGray.withAlphaComponent(0.35))
        }
        switch level {
        case .unknown:
            return MenuStyle.colorSwatch(.systemGray.withAlphaComponent(0.35))
        default:
            return MenuStyle.colorSwatch(MenuStyle.statusRayColor(for: level))
        }
    }

    /// Human-readable time label like "2m ago" / "3h ago" / "Apr 17,
    /// 14:22" for backup entries.
    static func relativeTimeLabel(for date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }

    // MARK: - Usage line

    /// Read Claude's live rate-limit state for `profile`. For the active
    /// account we read the LIVE Claude folder (freshest). For inactive
    /// accounts we read the Swivel snapshot — as-of the last save or
    /// switch, which is the best signal we have without launching
    /// Claude under that account.
    private func usageSnapshot(for profile: String, active: String?) -> UsageSnapshot? {
        let isActive = (profile == active)
        let dir: URL? = isActive
            ? manager.liveClaudeDir
            : manager.snapshotClaudeDir(for: profile)
        guard let dir = dir else { return nil }
        return ProfileUsageReader.read(claudeDir: dir)
    }

    /// Build the `UsageHeaderView`-backed menu item and prepend it to
    /// the menu, between the service-status alert and the account
    /// list. Skipped entirely when we can't recover any usage data —
    /// no sense showing an empty header.
    private func addUsageHeader(to menu: NSMenu, profiles: [String], active: String?) {
        // Gather a snapshot per profile. Retain the ordering from
        // the profile list so the header's rows map 1:1 to the
        // account rows below.
        let rows: [UsageHeaderView.Row] = profiles.map { name in
            UsageHeaderView.Row(
                name: name,
                colorHex: manager.profileColorHex(for: name),
                isActive: name == active,
                usage: usageSnapshot(for: name, active: active)
            )
        }
        // Hide the section entirely if nothing actionable is present.
        // A pile of "—" rows is worse than nothing.
        guard rows.contains(where: { $0.usage != nil }) else { return }

        let view = UsageHeaderView(rows: rows)
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        menu.addItem(item)
        menu.addItem(.separator())
    }

}
