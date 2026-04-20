# Architecture

This document describes how Swivel works internally. Aimed at
contributors and anyone who wants to verify the crash-safety and
security claims in the README.

## Overview

Swivel is a macOS menu bar app that saves per-account snapshots of
Claude Desktop's session state and swaps them in on demand.

The core state machine is small:

```
            ┌─────────────┐
            │  idle       │
            └──┬───────┬──┘
  "Add ..."│   │       │  "⌘⌥1" / click
  "Update" │   │       ▼
           │   │  ┌─────────────┐    pre-flight checks fail
           │   │  │  confirm    │──────────────────┐
           │   │  └──────┬──────┘                  │
           │   │         │ confirmed                │
           │   ▼         ▼                          │
        ┌──────────────────────┐                    │
        │  switch in flight    │◀───── beep on      │
        │  (background queue)  │       reentrant     │
        └──────────┬───────────┘       press         │
                   │                                │
                   ▼                                ▼
            success / failure ──────────────▶  back to idle
```

## Module layout

| Module | What it owns |
|--------|--------------|
| `AppDelegate` | `NSStatusItem`, hotkey registration, menu rebuild, all `@objc` action handlers, the menu bar icon rendering |
| `SwitchCoordinator` | The `isSwitching` flag + background-queue dispatch for switches |
| `ProfileManager` | Everything on disk: snapshots, manifests, backups, `state.json`, the keychain read |
| `MenuBuilder` | NSMenu composition, color palette, swatch rendering |
| `ClaudeAppController` | `NSRunningApplication` quit/launch + wait helpers |
| `ClaudeStatusChecker` | Polling the public status page, adaptive cadence |
| `KeychainHelper` | One-shot read of the `Claude Safe Storage` keychain item |
| `HotkeyManager` | Carbon Hot Key API wrapper |
| `LoginItemManager` | `SMAppService` wrapper |

## On-disk layout

Everything Swivel owns lives under
`~/Library/Application Support/Swivel/`:

```
Swivel/
├── state.json                        # active + previous profile pointers, color map
└── profiles/
    ├── Personal/
    │   ├── Claude/                   # the committed snapshot of Claude/
    │   │   ├── Session Storage/
    │   │   ├── IndexedDB/
    │   │   ├── ...
    │   │   └── .swivel-manifest.json # SHA-256 manifest (stage-complete marker)
    │   ├── com.anthropic.claudefordesktop.plist
    │   ├── safe_storage.key          # mode 0600
    │   ├── Claude.backup.20260417-142205/
    │   └── Claude.backup.20260417-120112/
    └── Work/
        └── ...
```

### Excluded items

These Claude-dir entries are **not** snapshotted. They belong to Claude
Code CLI, which users generally want to keep across account swaps:

- `claude-code/`
- `claude-code-sessions/`
- `claude-code-vm/`
- `claude-cli-nodejs/`
- `Crashpad/` (crash reports, not useful to preserve)

See `excludedItems` in `ProfileManager.swift`.

## Atomic snapshot protocol

The goal: a crash at any point during a save must leave either the
prior committed snapshot or a complete new one — never a half-copied
mix.

### Stage

```swift
// 1. Create a staging directory inside the profile:
profile/
└── .staging-<uuid>/
    ├── Claude/
    └── com.anthropic.claudefordesktop.plist   // if present
```

Copying happens inside `.staging-<uuid>/`. The committed `Claude/`
directory is untouched throughout.

### Finalize

Once all files are staged, the manifest is written **last**:

```
profile/.staging-<uuid>/Claude/.swivel-manifest.json
```

The presence of a valid manifest inside a staging dir is the
"stage complete" marker. If any earlier step aborted, there is no
manifest and the next launch's cleanup sweep discards the staging dir.

### Promote

Each top-level artifact (`Claude/`, plist) is promoted individually via
`FileManager.replaceItemAt(_:withItemAt:)`. On APFS this is backed by
`renamex_np` with `RENAME_SWAP` — a single kernel operation that
atomically swaps two inode entries.

- A crash before promotion: profile is unchanged.
- A crash during the swap: kernel-atomic, so either the old or the new
  entry is in place.
- A crash between the Claude-swap and the plist-swap: profile has the
  new `Claude/` with the old `preferences.plist`. This is a cosmetic
  inconsistency (plist is window prefs, not session state) and the next
  save will re-align them.

### Crash recovery

`ProfileManager.init` runs `cleanOrphanedStagingDirs()` which deletes
any `.staging-*` directories that survived a prior crash. They are
always pre-commit by construction, so deletion is safe.

## Restore protocol

Restoring a profile is the mirror image, but with an extra integrity
pass:

1. **Verify the manifest.** Re-hash the profile's `Claude/` contents
   and every tracked file. Any discrepancy throws
   `ProfileError.manifestMismatch` and aborts the restore — the live
   Claude install is never touched. Older profiles without a manifest
   skip verification (logged as a warning).
2. **Verify the keychain key** still matches what was saved. A
   mismatch means the user reinstalled Claude and rotated the local
   safeStorage key; cookies would fail to decrypt.
3. **Wipe non-excluded items** from the live `~/Library/Application
   Support/Claude/`.
4. **Copy snapshot items** into place. The manifest file is explicitly
   skipped so Claude never sees `.swivel-manifest.json`.
5. **Atomic-swap the plist** via a `swivel-tmp-<uuid>` sibling file.

## Manifest format

```json
{
  "version": 1,
  "createdAt": "2026-04-17T21:33:11Z",
  "entries": {
    "Claude/Session Storage": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "Claude/IndexedDB": "...",
    "preferences.plist": "..."
  }
}
```

Hashes are SHA-256, hex-lowercase, computed as:

- **Regular file:** SHA-256 of the file contents (streamed in 64 KiB
  chunks to bound memory).
- **Directory:** a Merkle-style digest — for each child in
  lexicographic order, concatenate `{name}\0{child_hash}\n` and hash
  the result. Recurses.
- **Symlink:** hash of the literal string `symlink:<target>`. The
  target is not followed.

Deterministic within a filesystem snapshot; stable across
re-sorts and repacks.

## Concurrency

- **Main thread:** all UI, menu rebuilds, hotkey dispatch, NSAlerts,
  and the `isSwitching` flag in `SwitchCoordinator`.
- **Global `.userInitiated` queue:** the heavy switch work (file
  copy + Claude quit/launch) — so the menu bar icon can visibly
  reflect "switching…" without freezing.
- **URLSession callbacks** (status checker): arrive on a URLSession
  queue, hop to main before mutating `latest` or invoking the
  `onUpdate` callback.
- **Carbon hotkey callbacks:** arrive on whichever thread dispatches
  the Carbon event; `HotkeyManager.fire` re-dispatches to main before
  invoking the handler.

The `SwitchCoordinator.isSwitching` flag is touched only from the main
thread, guarded by `dispatchPrecondition(condition: .onQueue(.main))`.

## Keychain handling

The Electron `safeStorage` API encrypts cookies with a device-local key
stored as the `Claude Safe Storage` / `Claude Key` keychain item.
Swivel reads this key via `/usr/bin/security find-generic-password`.
Args are passed as an array to `Process`, never concatenated into a
shell string.

**Swivel does not write to the keychain.** Any `security` write (`-U`,
`-A`, delete+add) rebuilds the item's partition list from the caller's
code signature, stripping Claude's `teamid:` entry. The next Claude
launch would then get prompted because its team ID was gone from the
ACL. See the long comment in `ProfileManager.switchTo` for the full
reasoning.

On each switch, `verifyKeychainKeyMatches` compares the saved key to
the current keychain value and throws if they differ — which is how
reinstall-driven key rotation surfaces instead of silently corrupting
cookies.

## Release process

1. Update `CHANGELOG.md`:
   - Move `[Unreleased]` items into a new `[X.Y.Z]` section.
   - Add the date.
   - Add a new empty `[Unreleased]` above it.
2. Tag the commit: `git tag -s vX.Y.Z -m "Swivel X.Y.Z"`.
3. Push: `git push origin main --tags`.
4. The `release.yml` GitHub Actions workflow builds the app, zips it,
   and attaches the artifact to a draft GitHub Release named `vX.Y.Z`.
5. Review the release notes, publish.

For signed/notarized builds (Developer ID), you'll need to add the
`codesign --sign "Developer ID Application: …"` step and an Apple
notarization step. The current CI uses ad-hoc signing, which is
sufficient for "download and run on my own Mac" but triggers a
Gatekeeper warning on first launch.

## Threat model

Covered in [SECURITY.md](../SECURITY.md). In brief, Swivel defends
against data loss from partial writes, silent corruption, and
concurrent switches. It does not defend against local adversaries with
access to your user account — that's the OS's job.
