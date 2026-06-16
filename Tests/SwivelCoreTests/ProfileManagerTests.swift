import Testing
@testable import SwivelCore

/// Round-trips the on-disk profile/state logic against a temp home, so it
/// never touches the user's real Claude/Swivel data. Covers the parts that
/// don't require the keychain (color state + directory management);
/// keychain-coupled save/restore is left for a future integration test.
@Suite("ProfileManager")
struct ProfileManagerTests {
    let home: URL
    let manager: ProfileManager

    init() {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swivel-test-\(UUID().uuidString)")
        manager = ProfileManager(home: home)
    }

    /// Lay down a profile directory the way a save would, without the
    /// keychain-coupled `saveCurrent`.
    private func makeProfile(_ name: String) throws {
        let dir = home
            .appendingPathComponent("Library/Application Support/Swivel/profiles")
            .appendingPathComponent(name)
            .appendingPathComponent("Claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }

    @Test func colorRoundTrip() throws {
        defer { cleanup() }
        #expect(manager.profileColorHex(for: "Work") == nil)
        try manager.setProfileColorHex("#BE3A3A", for: "Work")
        #expect(manager.profileColorHex(for: "Work") == "#BE3A3A")
        try manager.setProfileColorHex(nil, for: "Work")
        #expect(manager.profileColorHex(for: "Work") == nil)
    }

    @Test func colorPersistsAcrossInstances() throws {
        defer { cleanup() }
        try manager.setProfileColorHex("#3559A1", for: "Personal")
        let reopened = ProfileManager(home: home)
        #expect(reopened.profileColorHex(for: "Personal") == "#3559A1")
    }

    @Test func listProfilesIsAlphabetical() throws {
        defer { cleanup() }
        #expect(manager.listProfiles() == [])
        try makeProfile("Work")
        try makeProfile("Personal")
        #expect(manager.listProfiles() == ["Personal", "Work"])
    }

    @Test func snapshotDirResolvesOnlyForExisting() throws {
        defer { cleanup() }
        #expect(manager.snapshotClaudeDir(for: "Ghost") == nil)
        try makeProfile("Real")
        #expect(manager.snapshotClaudeDir(for: "Real") != nil)
    }

    @Test func deleteRemovesProfile() throws {
        defer { cleanup() }
        try makeProfile("Temp")
        #expect(manager.listProfiles().contains("Temp"))
        try manager.delete(profile: "Temp")
        #expect(manager.listProfiles().contains("Temp") == false)
    }

    // MARK: - Backup ring + restore (keychain-free file logic)

    @Test func restoreBackupRewindsAndPreservesCurrent() throws {
        defer { cleanup() }
        let fm = FileManager.default
        let profileDir = home
            .appendingPathComponent("Library/Application Support/Swivel/profiles/P")
        let current = profileDir.appendingPathComponent("Claude")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try "current".write(to: current.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        // A historical backup with distinct content.
        let backupDir = profileDir.appendingPathComponent("Claude.backup.20260101-120000")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try "old".write(to: backupDir.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        let backups = manager.listBackups(for: "P")
        #expect(backups.count == 1)
        try manager.restoreBackup(backups[0], profile: "P")

        // Current now holds the backup's content…
        let restored = try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8)
        #expect(restored == "old")
        // …and the prior current was preserved as a fresh backup (undo-the-undo).
        let after = manager.listBackups(for: "P")
        #expect(after.count == 1)
        let preserved = try String(
            contentsOf: profileDir.appendingPathComponent(after[0].directoryName).appendingPathComponent("marker"),
            encoding: .utf8
        )
        #expect(preserved == "current")
    }

    @Test func listBackupsNewestFirst() throws {
        defer { cleanup() }
        let fm = FileManager.default
        let profileDir = home
            .appendingPathComponent("Library/Application Support/Swivel/profiles/P")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        for stamp in ["20260101-090000", "20260301-090000", "20260201-090000"] {
            try fm.createDirectory(
                at: profileDir.appendingPathComponent("Claude.backup.\(stamp)"),
                withIntermediateDirectories: true
            )
        }
        let names = manager.listBackups(for: "P").map { $0.directoryName }
        #expect(names == [
            "Claude.backup.20260301-090000",
            "Claude.backup.20260201-090000",
            "Claude.backup.20260101-090000",
        ])
    }

    @Test func sweepsOrphanedRestoreStaging() throws {
        defer { cleanup() }
        let fm = FileManager.default
        let swivelRoot = home.appendingPathComponent("Library/Application Support/Swivel")
        let orphan = swivelRoot.appendingPathComponent(".restore-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        #expect(fm.fileExists(atPath: orphan.path))
        _ = ProfileManager(home: home)   // init runs the orphan sweep
        #expect(fm.fileExists(atPath: orphan.path) == false)
    }

    @Test func sweepsOrphanedSnapshotStaging() throws {
        defer { cleanup() }
        let fm = FileManager.default
        let orphan = home
            .appendingPathComponent("Library/Application Support/Swivel/profiles/P")
            .appendingPathComponent(".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        _ = ProfileManager(home: home)
        #expect(fm.fileExists(atPath: orphan.path) == false)
    }
}
