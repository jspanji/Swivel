import AppKit
import Combine

/// Everything a row in the popover/widget needs to render one account.
/// Snapshot value type — rebuilt wholesale on every refresh rather than
/// mutated, so SwiftUI diffing stays trivial.
struct AccountDisplay: Identifiable {
    let name: String
    let colorHex: String?
    let isActive: Bool
    let isPrevious: Bool
    /// "⌘⌥1"…"⌘⌥9" for the first nine alphabetical profiles, mirroring
    /// HotkeyManager's binding order. Nil from the tenth on.
    let shortcutHint: String?
    let usage: UsageSnapshot?
    /// Live usage fetched from claude.ai when the opt-in is enabled.
    /// nil when the feature is off or the fetch failed (expired cookie,
    /// key mismatch, offline) — in which case the row falls back to
    /// `usage` (the local cache).
    let liveUsage: LiveUsage?
    let backups: [BackupInfo]

    var id: String { name }
}

/// Intents flowing from the SwiftUI surfaces back to AppDelegate's
/// existing handlers (NSAlert dialogs, SwitchCoordinator, Sparkle…).
/// Closures rather than a protocol so AppDelegate can bundle private
/// methods without widening its API, and so every closure can uniformly
/// close the popover before presenting a modal.
struct UIActions {
    var switchTo: (String) -> Void = { _ in }
    var flip: () -> Void = {}
    var addAccount: () -> Void = {}
    var updateCurrent: () -> Void = {}
    var rename: (String) -> Void = { _ in }
    var delete: (String) -> Void = { _ in }
    var restoreBackup: (_ profile: String, _ backupDirName: String) -> Void = { _, _ in }
    var setColor: (_ profile: String, _ hex: String?) -> Void = { _, _ in }
    var toggleLoginItem: () -> Void = {}
    var toggleWidget: () -> Void = {}
    var toggleLiveUsage: () -> Void = {}
    var openStatusPage: () -> Void = {}
    var about: () -> Void = {}
    var help: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var quit: () -> Void = {}
}

/// Single observable source of truth for both SwiftUI surfaces (popover
/// + desktop widget). Owned by AppDelegate, which calls `refresh()`
/// everywhere it used to call `rebuildMenu()` — the menu was rebuilt
/// from scratch each time; here the published snapshot is rebuilt
/// instead and SwiftUI re-renders what changed.
final class SwivelViewModel: ObservableObject {
    @Published private(set) var accounts: [AccountDisplay] = []
    @Published private(set) var activeName: String?
    @Published private(set) var previousName: String?
    @Published private(set) var serviceStatus: ClaudeStatusSnapshot?
    @Published private(set) var loginItemAvailable = false
    @Published private(set) var loginItemEnabled = false
    @Published var widgetVisible = false
    @Published var widgetAlwaysOnTop = false
    /// Opt-in: fetch live usage from claude.ai. Off by default. Persisted
    /// in UserDefaults; mirrored here so the toggle's checkmark updates.
    @Published var liveUsageEnabled = UserDefaults.standard.bool(forKey: liveUsageDefaultsKey)

    static let liveUsageDefaultsKey = "liveUsageEnabled"

    private let manager: ProfileManager
    private let statusChecker: ClaudeStatusChecker
    private let usageService = UsageService()

    /// Generation counter so a slow background usage read can't clobber
    /// the results of a newer refresh that finished first.
    private var refreshGeneration = 0

    init(manager: ProfileManager, statusChecker: ClaudeStatusChecker) {
        self.manager = manager
        self.statusChecker = statusChecker
    }

    /// Rebuild the published snapshot. Profile metadata (names, colors,
    /// backups, active/previous) is cheap synchronous disk access and
    /// publishes immediately; usage snapshots involve LevelDB parsing,
    /// so they're read on a utility queue and merged in when done
    /// (the reader's mtime cache makes repeat reads nearly free).
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))

        let profiles = manager.listProfiles()
        let active = manager.activeProfile()
        let previous = manager.previousProfile()

        activeName = active
        previousName = previous
        serviceStatus = statusChecker.latest
        loginItemAvailable = LoginItemManager.isAvailable
        loginItemEnabled = LoginItemManager.isEnabled

        // Carry the last-known usage forward into this first pass rather than
        // blanking it. Profile metadata (names/colors/active) still publishes
        // instantly, but the usage lines keep their values so row heights stay
        // constant — otherwise, in live mode, every row collapses from its
        // 5h/7d pair to a single "no data" line and the persistent Usage
        // Overlay snaps shut and springs back open every refresh tick (and on
        // wake), a visible flicker. The async load below swaps in fresh numbers
        // in place. liveUsage is only carried while the opt-in is on, so
        // turning it off still drops the live lines immediately.
        let prior = Dictionary(accounts.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let base: [AccountDisplay] = profiles.enumerated().map { idx, name in
            AccountDisplay(
                name: name,
                colorHex: manager.profileColorHex(for: name),
                isActive: name == active,
                isPrevious: name == previous,
                shortcutHint: idx < 9 ? "⌘⌥\(idx + 1)" : nil,
                usage: prior[name]?.usage,
                liveUsage: liveUsageEnabled ? prior[name]?.liveUsage : nil,
                backups: manager.listBackups(for: name)
            )
        }
        accounts = base

        refreshGeneration += 1
        let generation = refreshGeneration
        let liveDir = manager.liveClaudeDir
        let dirs: [(name: String, dir: URL?)] = profiles.map { name in
            (name, name == active ? liveDir : manager.snapshotClaudeDir(for: name))
        }

        // UsageService does the heavy lifting: parallel per-account reads,
        // one keychain read, and single-flight so overlapping refreshes
        // coalesce instead of stacking network work.
        usageService.load(accounts: dirs, wantLive: liveUsageEnabled) { [weak self] usageByName in
            guard let self = self, self.refreshGeneration == generation else { return }
            self.accounts = base.map { row in
                let u = usageByName[row.name]
                return AccountDisplay(
                    name: row.name,
                    colorHex: row.colorHex,
                    isActive: row.isActive,
                    isPrevious: row.isPrevious,
                    shortcutHint: row.shortcutHint,
                    usage: u?.local,
                    liveUsage: u?.live,
                    backups: row.backups
                )
            }
        }
    }

    /// Flip the opt-in, persist it, and trigger an immediate refresh so the
    /// change is visible right away. Caller (AppDelegate) handles the
    /// first-enable confirmation dialog.
    func setLiveUsage(_ on: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        liveUsageEnabled = on
        UserDefaults.standard.set(on, forKey: Self.liveUsageDefaultsKey)
        refresh()
    }
}
