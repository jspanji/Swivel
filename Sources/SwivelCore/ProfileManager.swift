import Foundation
import os.log

enum ProfileError: LocalizedError {
    case claudeDirMissing
    case profileNotFound(String)
    case invalidName(String)
    case keychainReadFailed(String)
    case claudeDidNotQuit
    case ioFailure(String)
    case manifestMismatch(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .claudeDirMissing: return "Claude Desktop directory not found. Launch Claude at least once first."
        case .profileNotFound(let n): return "Profile \"\(n)\" not found."
        case .invalidName(let n): return "Invalid profile name: \(n)"
        case .keychainReadFailed(let m): return "Keychain read failed: \(m)"
        case .claudeDidNotQuit: return "Claude Desktop did not quit in time. Please close it manually and try again."
        case .ioFailure(let m): return "File operation failed: \(m)"
        case .manifestMismatch(let m): return "Profile snapshot integrity check failed: \(m). Restore a backup or re-save this account."
        case .busy: return "Another account operation is in progress. Try again in a moment."
        }
    }
}

/// One saved backup of a profile's Claude snapshot, kept under the profile
/// directory as `Claude.backup.<timestamp>`. Used for the backup ring so a
/// bad save (e.g. logged-out state) can be rolled back.
struct BackupInfo {
    let directoryName: String   // e.g. "Claude.backup.20260417-142205"
    let date: Date
}

final class ProfileManager {
    private let fm = FileManager.default
    private let home: URL
    private static let log = Logger(subsystem: "com.swivel.app", category: "ProfileManager")

    // Paths owned by Claude Desktop.
    private let claudeDir: URL
    // Our own state.
    private let rootDir: URL
    private let profilesDir: URL
    private let stateFile: URL

    // How many historical snapshots to keep per profile (in addition to
    // the current `Claude/` dir). Set low since each snapshot can be 100+MB.
    private let backupRingSize = 3

    // Serializes every operation that mutates the live Claude directory
    // (switch / save / update / restore-backup) so they can never interleave
    // and corrupt the live session: switches run on a background queue while
    // the save/update/restore actions fire on the main thread. Background
    // work blocks to take the gate; main-thread actions acquire without
    // blocking and throw `.busy` rather than freeze the UI.
    private let mutationGate = DispatchSemaphore(value: 1)

    private static let backupDirPrefix = "Claude.backup."
    private static let backupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Reserved filename for the per-snapshot integrity manifest. Lives
    // INSIDE each `Claude/` snapshot so it atomically moves with the
    // snapshot directory. Skipped during restore so the live Claude
    // install never sees it.
    private static let manifestFileName = ".swivel-manifest.json"
    private static let manifestVersion = 1

    // Items inside the Claude folder we explicitly do NOT copy during
    // snapshot, and do NOT wipe during restore. Falls into three groups:
    //
    // 1. **Claude Code state** — belongs to the CLI, not the GUI. Users
    //    don't want terminal sessions swapped with GUI accounts.
    //
    // 2. **Huge device-level data** — VM bundles and the Chromium HTTP
    //    cache add up to ~11 GB+ on a typical install. None of it is
    //    session-critical (the web cache rebuilds; VM images are
    //    per-device, not per-account). Copying + hashing it made
    //    switches take many seconds; excluding it drops snapshot size
    //    by ~1200× to a few MB of actual session data.
    //
    // 3. **Ephemeral caches** — GPU shader caches, Dawn caches,
    //    compressed-dictionary caches. All rebuild on demand. No
    //    reason to carry them across a profile switch.
    //
    // What IS still snapshotted (the important set): Cookies,
    // IndexedDB, Local Storage, Session Storage, Partitions,
    // WebStorage, claude_desktop_config.json (MCP servers — per-
    // account!), config.json, plist, network/trust metadata.
    private let excludedItems: Set<String> = [
        // Group 1 — Claude Code CLI state
        "claude-code",
        "claude-code-sessions",
        "claude-code-vm",
        "claude-cli-nodejs",

        // Group 2 — huge, not session
        "vm_bundles",
        "Cache",
        "Code Cache",
        "local-agent-mode-sessions",

        // Group 3 — ephemeral caches
        "GPUCache",
        "DawnWebGPUCache",
        "DawnGraphiteCache",
        "Shared Dictionary",

        // Error telemetry / crash state — not session
        "Crashpad",
        "sentry"
    ]

    convenience init() {
        self.init(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Designated init with an injectable home root — production passes the
    /// real home; tests pass a temp directory so a round-trip never touches
    /// the user's real Claude/Swivel data. All paths derive from `home`
    /// exactly as the default does.
    init(home: URL) {
        self.home = home
        self.claudeDir = home.appendingPathComponent("Library/Application Support/Claude")
        self.rootDir = home.appendingPathComponent("Library/Application Support/Swivel")

        self.profilesDir = rootDir.appendingPathComponent("profiles")
        self.stateFile = rootDir.appendingPathComponent("state.json")
        do {
            try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        } catch {
            Self.log.error("profilesDir create failed: \(error.localizedDescription, privacy: .public)")
        }

        // Sweep any leftover staging / trash directories from a prior
        // crash-mid-snapshot. We do this at init rather than lazily so
        // disk usage doesn't accumulate silently.
        cleanOrphanedStagingDirs()
    }

    // Run `body` while holding the mutation gate, blocking until it's free.
    // For background work (the switch flow) where a brief wait is fine.
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        mutationGate.wait()
        defer { mutationGate.signal() }
        return try body()
    }

    // Run `body` only if the mutation gate is free right now; otherwise throw
    // `.busy`. For main-thread actions, so a switch in flight can't hang the UI.
    private func tryLocked<T>(_ body: () throws -> T) throws -> T {
        guard mutationGate.wait(timeout: .now()) == .success else { throw ProfileError.busy }
        defer { mutationGate.signal() }
        return try body()
    }

    // MARK: - Public API

    /// The live Claude Desktop Application Support directory. Contains
    /// whatever session is currently loaded (usually the active
    /// profile's state, unless a switch is in flight).
    var liveClaudeDir: URL { claudeDir }

    /// Snapshot of `Claude/` inside the given profile, or `nil` if the
    /// profile doesn't exist / hasn't been saved yet.
    func snapshotClaudeDir(for profile: String) -> URL? {
        let dir = profilesDir.appendingPathComponent(profile).appendingPathComponent("Claude")
        return fm.fileExists(atPath: dir.path) ? dir : nil
    }

    func listProfiles() -> [String] {
        guard let entries = try? fm.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    func activeProfile() -> String? {
        readState()["activeProfile"] as? String
    }

    /// The profile that was active *before* the current one. Used by the
    /// "flip back to previous account" hotkey. Nil if there's only ever
    /// been one active profile on this machine.
    func previousProfile() -> String? {
        readState()["previousProfile"] as? String
    }

    private func readState() -> [String: Any] {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    func saveCurrent(as name: String) throws {
        try validateName(name)
        guard fm.fileExists(atPath: claudeDir.path) else { throw ProfileError.claudeDirMissing }
        let target = profilesDir.appendingPathComponent(name)

        try tryLocked {
            // Before overwriting the existing `Claude/` snapshot, rotate it into
            // a timestamped backup so we can roll back if this save turned out
            // to capture a bad state (e.g. the user was logged out).
            try rotateBackupIfPresent(in: target)

            try snapshotClaudeFolder(into: target)
            try snapshotKeychainKey(into: target)
            pruneBackups(in: target)
            try setActiveProfile(name)
        }
    }

    func delete(profile name: String) throws {
        let dir = profilesDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: dir.path) else { throw ProfileError.profileNotFound(name) }
        try fm.removeItem(at: dir)
        if activeProfile() == name { try setActiveProfile(nil) }
        try? setProfileColorHex(nil, for: name)
    }

    /// Refresh the snapshot of the currently-active account from Claude's
    /// live state. Same rotation/prune semantics as `saveCurrent(as:)` but
    /// no dialog — used for one-click "Update <Account>".
    func updateCurrent() throws {
        guard let active = activeProfile() else {
            throw ProfileError.ioFailure("No active account to update.")
        }
        guard fm.fileExists(atPath: claudeDir.path) else { throw ProfileError.claudeDirMissing }
        let target = profilesDir.appendingPathComponent(active)
        try tryLocked {
            try rotateBackupIfPresent(in: target)
            try snapshotClaudeFolder(into: target)
            try snapshotKeychainKey(into: target)
            pruneBackups(in: target)
        }
    }

    /// Rename an account. Moves the on-disk profile directory and updates
    /// all references in state (active pointer, previous pointer, colors).
    /// Backups travel with the profile automatically since they live inside
    /// its directory.
    func rename(profile oldName: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateName(trimmed)
        guard oldName != trimmed else { return }

        let oldDir = profilesDir.appendingPathComponent(oldName)
        let newDir = profilesDir.appendingPathComponent(trimmed)
        guard fm.fileExists(atPath: oldDir.path) else { throw ProfileError.profileNotFound(oldName) }
        if fm.fileExists(atPath: newDir.path) {
            throw ProfileError.invalidName("An account named \"\(trimmed)\" already exists.")
        }

        try fm.moveItem(at: oldDir, to: newDir)

        // Rewrite state references so active/previous pointers and the
        // color map follow the rename.
        var state = readState()
        if (state["activeProfile"] as? String) == oldName {
            state["activeProfile"] = trimmed
        }
        if (state["previousProfile"] as? String) == oldName {
            state["previousProfile"] = trimmed
        }
        if var colors = state["colors"] as? [String: String] {
            if let hex = colors.removeValue(forKey: oldName) {
                colors[trimmed] = hex
            }
            state["colors"] = colors
        }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
        try data.write(to: stateFile, options: .atomic)
    }

    /// Set of hex strings (uppercased) currently assigned to any account.
    /// Used to auto-pick a fresh color when a new account is saved.
    func assignedColorHexes() -> Set<String> {
        let colors = readState()["colors"] as? [String: String] ?? [:]
        return Set(colors.values.map { $0.uppercased() })
    }

    // MARK: - Per-profile color

    /// Hex color string (e.g. "#34C759") chosen by the user for this profile,
    /// or nil if unset. Used for the menu bar icon background so the active
    /// account is visually distinct at a glance.
    func profileColorHex(for profile: String) -> String? {
        let colors = readState()["colors"] as? [String: String]
        return colors?[profile]
    }

    func setProfileColorHex(_ hex: String?, for profile: String) throws {
        var state = readState()
        var colors = (state["colors"] as? [String: String]) ?? [:]
        if let hex = hex {
            colors[profile] = hex
        } else {
            colors.removeValue(forKey: profile)
        }
        state["colors"] = colors
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted])
        try data.write(to: stateFile, options: .atomic)
    }

    /// Orchestrates the swap: save-current → quit Claude → restore target → relaunch.
    func switchTo(profile name: String, progress: @escaping (String) -> Void) throws {
        try locked {
            let target = profilesDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: target.path) else { throw ProfileError.profileNotFound(name) }

            progress("Quitting Claude…")
            ClaudeAppController.quit()
            guard ClaudeAppController.waitUntilQuit(timeout: 10) else { throw ProfileError.claudeDidNotQuit }

            // Verify the target's saved keychain key matches the current Claude
            // install BEFORE touching the live folder. If they diverge (e.g. the
            // user reinstalled Claude), the restored cookies wouldn't decrypt —
            // surface that now, while the live session is still intact, rather
            // than after we've wiped it.
            //
            // NOTE: we deliberately do NOT rewrite the keychain key on switch.
            // Electron's safeStorage key is a device-local secret generated once
            // per install and never rotated, so both profiles' saved keys already
            // match the current value. More importantly, ANY `security` CLI write
            // (`-U`, `-A`, or delete+add) strips the app's `teamid:` entry from
            // the item's partition list (rebuilt from the caller's code signature
            // on every write), so the next Claude launch would prompt.
            try verifyKeychainKeyMatches(profile: target)

            // Snapshot current state back into the active profile so the current
            // session isn't lost. Rotate a backup first (mirroring saveCurrent),
            // so the outgoing account keeps a rollback point even if its live
            // state was bad. We do NOT re-snapshot the keychain key here — same
            // partition-list reasoning as above.
            if let current = activeProfile(), current != name {
                progress("Saving current session to \(current)…")
                let currentProfile = profilesDir.appendingPathComponent(current)
                try rotateBackupIfPresent(in: currentProfile)
                try snapshotClaudeFolder(into: currentProfile)
                pruneBackups(in: currentProfile)
            }

            progress("Restoring \(name)…")
            try restoreClaudeFolder(from: target)
            try setActiveProfile(name)

            progress("Launching Claude…")
            ClaudeAppController.launch()
        }
    }

    // MARK: - Snapshot / restore (atomic via staging + rename)

    /// Capture the live Claude folder + preferences plist into `profileDir`
    /// with crash-safe atomicity. Everything is staged under a sibling
    /// `.staging-<uuid>/` directory first; the manifest is written last as
    /// the "stage complete" marker. Only after the stage is complete do we
    /// atomically promote the staged `Claude/` and plist into the profile.
    ///
    /// A crash before promotion leaves the old `Claude/` untouched — the
    /// staging dir is orphaned and swept on the next ProfileManager init.
    /// The promotion itself uses `FileManager.replaceItemAt`, which manages
    /// its own temp + rollback, so a crash mid-promotion leaves either the
    /// old or the new directory in place.
    private func snapshotClaudeFolder(into profileDir: URL) throws {
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let stagingID = UUID().uuidString
        let staging = profileDir.appendingPathComponent(".staging-\(stagingID)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        // Ensure the staging dir is cleaned up on ANY exit path — success
        // (in which case it's already empty) or failure (in which case we
        // want to reclaim the partial data).
        var stagingReleased = false
        defer {
            if !stagingReleased, fm.fileExists(atPath: staging.path) {
                do {
                    try fm.removeItem(at: staging)
                } catch {
                    Self.log.error("staging cleanup failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let stagedClaude = staging.appendingPathComponent("Claude")
        try fm.createDirectory(at: stagedClaude, withIntermediateDirectories: true)

        // Copy live Claude entries into the staging dir, skipping excluded
        // items (Claude Code CLI state doesn't belong in account swaps).
        let entries = try fm.contentsOfDirectory(
            at: claudeDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            if excludedItems.contains(name) { continue }
            let dest = stagedClaude.appendingPathComponent(name)
            do {
                try fm.copyItem(at: entry, to: dest)
            } catch {
                throw ProfileError.ioFailure("copying \(name): \(error.localizedDescription)")
            }
        }

        // Stage the preferences plist alongside so it's included in the
        // atomic promotion. No more `try?` — plist problems are real
        // failures that must surface.
        let plist = home.appendingPathComponent("Library/Preferences/com.anthropic.claudefordesktop.plist")
        let plistStaged: URL? = {
            guard fm.fileExists(atPath: plist.path) else { return nil }
            let dest = staging.appendingPathComponent("com.anthropic.claudefordesktop.plist")
            return dest
        }()
        if let plistStaged = plistStaged {
            do {
                try fm.copyItem(at: plist, to: plistStaged)
            } catch {
                throw ProfileError.ioFailure("copying preferences plist: \(error.localizedDescription)")
            }
        }

        // Build + write the manifest LAST. Its presence inside the staged
        // Claude/ is the "stage complete" marker; if a crash truncates any
        // earlier step, there's no manifest, and the stage is discarded.
        let manifest = try buildManifest(forSnapshotAt: stagedClaude, plistAt: plistStaged)
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        let manifestURL = stagedClaude.appendingPathComponent(Self.manifestFileName)
        try manifestData.write(to: manifestURL, options: .atomic)

        // ── Promotion ──────────────────────────────────────────────────
        // Each promotion is individually atomic (see `atomicPromote`).
        // Between the Claude/ and plist promotions there's a brief window
        // where the profile could reference a new Claude but an old plist;
        // that mismatch is cosmetic (plist is preferences, not session
        // data), so we don't guard it with a fancier protocol.
        let liveClaude = profileDir.appendingPathComponent("Claude")
        try atomicPromote(staged: stagedClaude, to: liveClaude)

        if let plistStaged = plistStaged {
            let liveProfilePlist = profileDir.appendingPathComponent("com.anthropic.claudefordesktop.plist")
            try atomicPromote(staged: plistStaged, to: liveProfilePlist)
        }

        stagingReleased = true
    }

    /// Restore a profile's saved session over the live Claude install.
    /// Verifies the profile's manifest before touching the live folder —
    /// if a snapshot is corrupt or partial (e.g. from a pre-manifest save
    /// that crashed mid-copy), we refuse to propagate the damage.
    private func restoreClaudeFolder(from profileDir: URL) throws {
        let snapshotDir = profileDir.appendingPathComponent("Claude")
        guard fm.fileExists(atPath: snapshotDir.path) else {
            throw ProfileError.ioFailure("snapshot missing for profile at \(profileDir.path)")
        }
        let plistSnapshot = profileDir.appendingPathComponent("com.anthropic.claudefordesktop.plist")
        let plistSnapshotExists = fm.fileExists(atPath: plistSnapshot.path)

        try verifyManifest(
            forSnapshotAt: snapshotDir,
            plistAt: plistSnapshotExists ? plistSnapshot : nil
        )

        // ── Phase 1: stage, WITHOUT touching the live install ───────────
        // Copy the snapshot's entries into a staging dir first. The copy is
        // the slow, failure-prone step (disk-full, I/O error, a bad entry);
        // doing it before any destruction means a failure here leaves the
        // live Claude session completely intact. (The previous wipe-then-copy
        // could leave it half-destroyed if a copy failed mid-restore.)
        // Staging lives under our rootDir — same volume as claudeDir, so the
        // promotion below is a rename, not a copy — and is swept on init if a
        // crash orphans it.
        let staging = rootDir.appendingPathComponent(".restore-staging-\(UUID().uuidString)")
        defer {
            if fm.fileExists(atPath: staging.path) {
                try? fm.removeItem(at: staging)
            }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var stagedNames: Set<String> = []
        let snapEntries = try fm.contentsOfDirectory(at: snapshotDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for entry in snapEntries {
            // Manifest file is our own bookkeeping — never propagate it into
            // Claude's live directory.
            if entry.lastPathComponent == Self.manifestFileName { continue }
            let name = entry.lastPathComponent
            do {
                try fm.copyItem(at: entry, to: staging.appendingPathComponent(name))
            } catch {
                throw ProfileError.ioFailure("staging \(name): \(error.localizedDescription)")
            }
            stagedNames.insert(name)
        }

        // ── Phase 2: commit, via fast same-volume renames ───────────────
        // All snapshot data is now on disk in `staging`, so promoting each
        // entry into the live dir is a rename (individually atomic), not a
        // copy. We never blank the live dir: each entry is swapped in place,
        // then only stale NON-excluded entries (left over from the previously
        // loaded account) are removed. Excluded items (Claude Code state,
        // caches) are never touched.
        if !fm.fileExists(atPath: claudeDir.path) {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        }
        for name in stagedNames {
            try atomicPromote(staged: staging.appendingPathComponent(name),
                              to: claudeDir.appendingPathComponent(name))
        }
        let liveEntries = try fm.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for entry in liveEntries {
            let name = entry.lastPathComponent
            if excludedItems.contains(name) || name == Self.manifestFileName { continue }
            if stagedNames.contains(name) { continue }
            try fm.removeItem(at: entry)
        }

        if plistSnapshotExists {
            let livePlist = home.appendingPathComponent("Library/Preferences/com.anthropic.claudefordesktop.plist")
            // Copy to a sibling temp file then rename, so a crash mid-copy
            // leaves the current plist untouched.
            let tmpPlist = livePlist.appendingPathExtension("swivel-tmp-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: plistSnapshot, to: tmpPlist)
                try atomicPromote(staged: tmpPlist, to: livePlist)
            } catch {
                if fm.fileExists(atPath: tmpPlist.path) {
                    do {
                        try fm.removeItem(at: tmpPlist)
                    } catch {
                        Self.log.error("plist tmp cleanup failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                throw ProfileError.ioFailure("restoring preferences plist: \(error.localizedDescription)")
            }
        }
    }

    /// Promote `staged` into `final` as atomically as the platform allows.
    /// When `final` exists we use `replaceItemAt`, which performs the swap
    /// and manages its own backup/rollback temp; on APFS this is typically a
    /// fast metadata operation. The guarantee we rely on is that a crash
    /// leaves either the old or the new item in place — never a half-merged
    /// one. When `final` doesn't exist yet we fall back to `moveItem`.
    private func atomicPromote(staged: URL, to final: URL) throws {
        if fm.fileExists(atPath: final.path) {
            // replaceItemAt swaps `final` and `staged` atomically, then
            // deletes the displaced item. Return URL is the final
            // location — we already know it, so discard.
            _ = try fm.replaceItemAt(final, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: final)
        }
    }

    /// Clean up any `.staging-*` orphans left by a prior crash. These
    /// are always pre-commit (never linked from anywhere), so deleting
    /// them is safe. Called from init so disk usage doesn't silently
    /// accumulate over many crash-retry cycles.
    private func cleanOrphanedStagingDirs() {
        // Restore-staging dirs (from an interrupted restore) live directly
        // under rootDir.
        if let rootChildren = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil) {
            for child in rootChildren where child.lastPathComponent.hasPrefix(".restore-staging-") {
                do {
                    try fm.removeItem(at: child)
                    Self.log.info("swept orphan restore-staging \(child.lastPathComponent, privacy: .public)")
                } catch {
                    Self.log.error("orphan sweep failed for \(child.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // Snapshot-staging dirs live inside each profile.
        guard let profiles = try? fm.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil) else { return }
        for profile in profiles {
            guard let children = try? fm.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil) else { continue }
            for child in children where child.lastPathComponent.hasPrefix(".staging-") {
                do {
                    try fm.removeItem(at: child)
                    Self.log.info("swept orphan staging \(child.lastPathComponent, privacy: .public)")
                } catch {
                    Self.log.error("orphan sweep failed for \(child.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func snapshotKeychainKey(into profileDir: URL) throws {
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let key: String
        do {
            key = try KeychainHelper.readSafeStorageKey()
        } catch {
            throw ProfileError.keychainReadFailed(error.localizedDescription)
        }
        let file = profileDir.appendingPathComponent("safe_storage.key")
        try key.data(using: .utf8)?.write(to: file, options: .atomic)
        // Best-effort lock down permissions; the folder is already in the
        // user's Application Support, but tighten file mode for safety.
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Self.log.error("chmod 600 on safe_storage.key failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Verify the saved key matches the current keychain key before switching.
    /// If they differ, cookie decryption would fail — surface the problem
    /// instead of silently installing cookies the user can't decrypt.
    private func verifyKeychainKeyMatches(profile profileDir: URL) throws {
        let file = profileDir.appendingPathComponent("safe_storage.key")
        guard let savedData = try? Data(contentsOf: file),
              let savedKey = String(data: savedData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !savedKey.isEmpty
        else {
            // Profile has no saved key (older format, or save failed). Don't
            // block the switch — most installs use a stable key, and the
            // file-level snapshot is what actually matters.
            return
        }
        let currentKey: String
        do {
            currentKey = try KeychainHelper.readSafeStorageKey()
        } catch {
            // If we can't read the current key, don't block — the switch can
            // still succeed if the key matches what's on disk.
            return
        }
        if savedKey != currentKey {
            throw ProfileError.keychainReadFailed(
                "Profile's saved safeStorage key differs from the current " +
                "Claude install. Cookies would not decrypt. Re-save this " +
                "profile from a logged-in Claude session to fix."
            )
        }
    }

    // MARK: - Manifest / integrity
    //
    // Earlier versions hashed every file with SHA-256 as a corruption
    // check. That turned a fast switch into a ~1-2 second one on large
    // Claude installs, and the coverage it added was almost entirely
    // redundant: atomic promotion via `renamex_np` guarantees the
    // snapshot is either fully there or fully not, and every storage
    // layer underneath us (APFS checksums, LevelDB CRC32, SQLite
    // integrity) catches content corruption at the FS/DB level.
    //
    // So the manifest is now just a completion marker + directory
    // listing. Its presence means "Swivel finished staging this
    // snapshot"; its entries let `verifyManifest` catch the narrow
    // case of top-level items disappearing between save and restore
    // (e.g. user manually deleted something inside the profile dir).

    /// Build a minimal manifest describing what was staged. No content
    /// hashing — see module comment above.
    private func buildManifest(forSnapshotAt snapshotDir: URL, plistAt plistStaged: URL?) throws -> [String: Any] {
        var entries: [String] = []

        let children = try fm.contentsOfDirectory(
            at: snapshotDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let name = child.lastPathComponent
            if name == Self.manifestFileName { continue }
            entries.append("Claude/\(name)")
        }

        if plistStaged != nil {
            entries.append("preferences.plist")
        }

        return [
            "version": Self.manifestVersion,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "entries": entries.sorted()
        ]
    }

    /// Verify the snapshot matches its manifest. Checks that every
    /// listed entry exists on disk; does NOT re-read content. If the
    /// manifest is missing (older profile, pre-manifest save) we skip
    /// verification and log — the restore still proceeds.
    ///
    /// Accepts both v1 manifests (entries: `[String: String]`, name →
    /// sha256) and the current schema (entries: `[String]`, names
    /// only). Forward-compatible, so users with older saved profiles
    /// don't have to re-save.
    private func verifyManifest(forSnapshotAt snapshotDir: URL, plistAt plistSnapshot: URL?) throws {
        let manifestURL = snapshotDir.appendingPathComponent(Self.manifestFileName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            Self.log.info("profile at \(snapshotDir.path, privacy: .public) has no manifest; skipping integrity check")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ProfileError.manifestMismatch("manifest unreadable: \(error.localizedDescription)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProfileError.manifestMismatch("manifest malformed")
        }

        let entryNames: [String]
        if let list = obj["entries"] as? [String] {
            entryNames = list
        } else if let dict = obj["entries"] as? [String: String] {
            // v1 manifest — keys are the names, values are now-ignored hashes.
            entryNames = Array(dict.keys)
        } else {
            throw ProfileError.manifestMismatch("manifest malformed")
        }

        // Check that every entry the manifest promised is still present.
        for entry in entryNames {
            let path: URL
            if entry == "preferences.plist" {
                guard let plist = plistSnapshot else {
                    throw ProfileError.manifestMismatch("missing plist snapshot")
                }
                path = plist
            } else if entry.hasPrefix("Claude/") {
                let rel = String(entry.dropFirst("Claude/".count))
                path = snapshotDir.appendingPathComponent(rel)
            } else {
                continue   // unknown shape; a future manifest version may add new prefixes
            }
            guard fm.fileExists(atPath: path.path) else {
                throw ProfileError.manifestMismatch("missing: \(entry)")
            }
        }
    }

    // MARK: - Backups

    /// List historical snapshots available for a profile, newest first.
    func listBackups(for profile: String) -> [BackupInfo] {
        let profileDir = profilesDir.appendingPathComponent(profile)
        guard fm.fileExists(atPath: profileDir.path),
              let entries = try? fm.contentsOfDirectory(at: profileDir, includingPropertiesForKeys: nil)
        else { return [] }

        return entries.compactMap { url -> BackupInfo? in
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.backupDirPrefix) else { return nil }
            let stamp = String(name.dropFirst(Self.backupDirPrefix.count))
            guard let date = Self.backupDateFormatter.date(from: stamp) else { return nil }
            return BackupInfo(directoryName: name, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Rewind a profile to a specific backup. The current snapshot is first
    /// rotated into a new backup (so you can undo the undo), then the
    /// selected backup is promoted to the current snapshot. Safe to call
    /// while Claude is running — the caller should quit it first for real
    /// use, but we don't require it here because callers may already have.
    func restoreBackup(_ backup: BackupInfo, profile: String) throws {
        let profileDir = profilesDir.appendingPathComponent(profile)
        let backupDir = profileDir.appendingPathComponent(backup.directoryName)
        let currentDir = profileDir.appendingPathComponent("Claude")
        guard fm.fileExists(atPath: backupDir.path) else {
            throw ProfileError.ioFailure("backup \(backup.directoryName) missing")
        }
        try tryLocked {
            // Preserve current state as a new backup before overwriting.
            try rotateBackupIfPresent(in: profileDir)
            try fm.moveItem(at: backupDir, to: currentDir)
            pruneBackups(in: profileDir)
        }
    }

    /// If `profileDir/Claude` exists, rename it to a timestamped backup
    /// directory. No-op if there's nothing to back up.
    private func rotateBackupIfPresent(in profileDir: URL) throws {
        let current = profileDir.appendingPathComponent("Claude")
        guard fm.fileExists(atPath: current.path) else { return }
        // Use file mdate if possible, else now. Mdate is more accurate to
        // when the snapshot was actually captured.
        let date = (try? current.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let stamp = Self.backupDateFormatter.string(from: date)
        var name = "\(Self.backupDirPrefix)\(stamp)"
        var candidate = profileDir.appendingPathComponent(name)
        // Collision-proof: if two backups would land on the same timestamp,
        // append a suffix.
        var suffix = 1
        while fm.fileExists(atPath: candidate.path) {
            name = "\(Self.backupDirPrefix)\(stamp)-\(suffix)"
            candidate = profileDir.appendingPathComponent(name)
            suffix += 1
        }
        do {
            try fm.moveItem(at: current, to: candidate)
        } catch {
            // Propagate — the caller is about to write a fresh Claude/ over
            // the top, so a silent rotation failure would destroy the only
            // copy of the pre-save state. Abort the operation instead.
            Self.log.error("backup rotation failed for \(profileDir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ProfileError.ioFailure("could not preserve the previous snapshot as a backup: \(error.localizedDescription)")
        }
    }

    /// Keep the newest `backupRingSize` backups; delete older ones.
    private func pruneBackups(in profileDir: URL) {
        let profile = profileDir.lastPathComponent
        let backups = listBackups(for: profile)   // newest first
        guard backups.count > backupRingSize else { return }
        for b in backups.suffix(from: backupRingSize) {
            let path = profileDir.appendingPathComponent(b.directoryName)
            do {
                try fm.removeItem(at: path)
            } catch {
                Self.log.error("pruning backup \(b.directoryName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - State

    /// Persist active profile plus a rolling "previous" pointer so the
    /// flip-to-last-profile hotkey has something to flip to.
    private func setActiveProfile(_ name: String?) throws {
        var obj = readState()
        let currentActive = obj["activeProfile"] as? String
        if let name = name {
            // Only rotate previous if we're actually changing accounts.
            if let old = currentActive, old != name {
                obj["previousProfile"] = old
            }
            obj["activeProfile"] = name
        } else {
            obj.removeValue(forKey: "activeProfile")
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try data.write(to: stateFile, options: .atomic)
    }

    private func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ProfileError.invalidName("Name can't be empty.")
        }
        // Disallow path / null / leading dot (hidden files).
        let illegalChars: Set<Character> = ["/", "\\", "\0", ":"]
        if trimmed.first == "." || trimmed.contains(where: { illegalChars.contains($0) }) {
            throw ProfileError.invalidName("Name contains characters that aren't allowed.")
        }
        if trimmed.count > 40 {
            throw ProfileError.invalidName("Name is too long (max 40 characters).")
        }
    }
}
