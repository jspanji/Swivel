# Changelog

All notable changes to Swivel are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Swivel
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-04-20

First public release.

### Added

- Menu bar app for switching between Claude Desktop accounts without
  logging out.
- Global hotkeys `⌘⌥1`–`⌘⌥9` (switch to account by slot) and `` ⌘⌥` ``
  (flip to the previous account).
- Per-account color presets. Active account's color renders into the menu
  bar icon so you can see which account is live at a glance.
- Claude service-status indicator in the menu bar icon and menu, driven by
  adaptive polling of the public status page.
- Atomic snapshot/restore with an APFS `renamex_np`-backed swap — a crash
  during a save or switch leaves either the old or new state on disk,
  never a partial merge.
- SHA-256 per-file manifest written inside every snapshot. Restores
  verify the manifest and refuse to propagate corruption to the live
  Claude install.
- Reentrancy guard on the switch flow so rapid hotkey presses don't queue
  overlapping swaps.
- Backup ring — each account keeps its last 3 snapshots automatically.
  Restore via **Manage ▸ \<Account\> ▸ Restore Backup**.
- Confirmation dialog when switching while Claude is frontmost (or was
  frontmost very recently), to protect unsent drafts.
- Launch-at-login toggle via `SMAppService`.
- One-time keychain read per account at first save — switches after that
  don't touch the keychain, so you don't get prompted on every switch.
- "View on GitHub" button in the About dialog and a **Help &
  Documentation** menu item linking to the project README.
- Crash-recovery sweep on launch that removes orphaned staging
  directories from a prior interrupted save.
- Structured logging via `os.Logger` throughout `ProfileManager`.

### Security

- Atomic snapshot promotion so a partial save can never overwrite a good
  profile with a corrupted one.
- Manifest verification before restoring session data into Claude's
  live Application Support directory.
- Keychain snapshot files written with mode 0600.
- Shell-safe `Process` invocation when reading the keychain — args are
  passed as an array, never concatenated into a shell string.

[Unreleased]: https://github.com/jspanji/Swivel/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jspanji/Swivel/releases/tag/v1.0.0
