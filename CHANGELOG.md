# Changelog

All notable changes to Swivel are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Swivel
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Auto-update via Sparkle 2. Swivel polls `appcast.xml` on a 24-hour
  cadence and offers verified EdDSA-signed updates. New
  **Check for Updates…** menu item lets users force a check.
  Users on 1.0.0 must manually install 1.1.0 once; from there auto-
  update takes over.
- Optional **Usage Overlay**: a translucent glass panel showing every
  account's usage at a glance. Floats on top of your windows by default
  (an "Always on Top" toggle tucks it behind them, visible on
  show-desktop); click an account to switch. Toggle it from the popover's
  gear menu — position and visibility persist across launches.
- Optional **Live Usage** (experimental, off by default): when enabled
  from the gear menu, Swivel fetches real-time 5-hour and 7-day utilization
  per account
  from claude.ai using each account's own saved session — always-on
  numbers, including for inactive accounts, instead of the local cache's
  pressure-only data. This is the only feature that makes a network
  request beyond the public status page; it requires an explicit opt-in
  with a confirmation, makes read-only requests, and falls back to the
  local cache when a session has expired. It depends on undocumented
  claude.ai endpoints, so it may break without notice.

### Changed

- The menu-bar dropdown is now a translucent **popover** (glass
  material) instead of a plain menu. Same features, one surface:
  per-account usage bars with plan / messages-left / reset-time detail,
  switch on click, hover "…" menu for Rename / Change Color / Restore
  Backup / Delete, and a footer with service status and settings.
  Right-click the menu bar icon for a compact About / Updates / Quit
  menu. Global hotkeys are unchanged.
- Usage color is now **calm by default**: a list of low-usage accounts
  reads neutral instead of a wall of color. Amber appears at ≥ 75% and
  red at ≥ 90% utilization, and a gauge fills only once an account is
  actually approaching or at a limit — color is reserved for accounts
  that need attention, matching the menu-bar icon's signal-by-absence
  behavior.
- Only recognized plans (Max, Pro, Free, Team, Enterprise) are labeled;
  unrecognized internal plan codenames are now hidden rather than shown
  as a raw identifier.

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
