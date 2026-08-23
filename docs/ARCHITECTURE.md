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

**Package layout.** The code is a `SwivelCore` library target plus a thin
`Swivel` executable (just `main.swift` → `launchSwivel()`). All logic and UI
live in `SwivelCore` so the `SwivelCoreTests` target can reach it via
`@testable import`. `build-app.sh` builds the `Swivel` executable product
exactly as before.

| Module | What it owns |
|--------|--------------|
| `AppDelegate` | `NSStatusItem`, hotkey registration, action handlers, `UIActions` wiring |
| `StatusIconRenderer` | Pure Core Graphics menu-bar icon drawing (testable, no state) |
| `ClaudeActivityMonitor` | Frontmost-Claude polling + "likely in use" heuristic |
| `Dialogs` | Modal alerts + banner notifications (UI-feedback primitives) |
| `UsageService` | Per-account usage: parallel live fetch, one keychain read, single-flight coalescing |
| `SwitchCoordinator` | The `isSwitching` flag + background-queue dispatch for switches |
| `ProfileManager` | Everything on disk: snapshots, manifests, backups, `state.json`, the keychain read |
| `SwivelViewModel` | `ObservableObject` source of truth for both SwiftUI surfaces; rebuilds its published snapshot wherever the old menu was rebuilt |
| `StatusItemController` | The translucent `NSPopover` (SwiftUI content), left/right-click routing, minimal right-click fallback `NSMenu` |
| `DesktopWidgetController` | The floating glass desktop widget: borderless non-activating `NSPanel`, window level, refresh timer, persistence |
| `PopoverRootView` / `WidgetRootView` / `AccountRowView` | SwiftUI view layer; `AccountRowView` is shared so both surfaces render accounts identically |
| `UsageFormatting` | Display logic for usage snapshots (tier labels, reset deltas, staleness, gauge rules) shared by popover + widget |
| `ProfileUsageReader` | Local-only usage: parses Claude Desktop's LocalStorage cache for `messageLimits` (present only under rate-limit pressure) |
| `LiveUsageClient` | **Opt-in only.** Decrypts an account's session cookie and fetches always-on 5h/7d utilization from claude.ai. The sole authenticated network path |
| `Theme` | Color palette (`MenuStyle`), swatch rendering, status colors, hex↔Color bridges |
| `ClaudeAppController` | `NSRunningApplication` quit/launch + wait helpers |
| `ClaudeStatusChecker` | Polling the public status page, adaptive cadence |
| `KeychainHelper` | One-shot read of the `Claude Safe Storage` keychain item |
| `HotkeyManager` | Carbon Hot Key API wrapper |
| `LoginItemManager` | `SMAppService` wrapper |

## UI layer

The status item's old `NSMenu` was replaced by a translucent `NSPopover`
hosting SwiftUI (`.ultraThinMaterial`), plus an optional floating glass
desktop widget — both fed by one `SwivelViewModel`:

```
                       AppDelegate
   hotkeys ──▶ performSwitch ──▶ SwitchCoordinator
   handlers (NSAlert dialogs — unchanged from the menu era)
        │                                ▲
        │ viewModel.refresh()            │ UIActions closures
        ▼                                │ (switch / rename / delete / …)
   SwivelViewModel (ObservableObject)    │
        │                                │
   ┌────┴─────────┐                      │
   ▼              ▼                      │
 StatusItemController   DesktopWidgetController
   NSPopover              NSPanel (borderless, non-activating)
   PopoverRootView        WidgetRootView
        └──── AccountRowView (shared) ────┘
```

Design points:

- **State flows down, intents flow up.** The view model republishes
  `ProfileManager` / `ProfileUsageReader` / `ClaudeStatusChecker` state;
  SwiftUI never mutates anything directly — every intent goes through a
  `UIActions` closure into the same AppDelegate handlers the menu used.
- **The popover closes before any modal.** Handlers run `NSApp.activate`
  + `runModal`, which would steal key status from a transient popover
  and dismiss it mid-interaction; closing first makes it deterministic.
- **`menuWillOpen` became `popoverWillShow`** (the `onWillShow` callback):
  status re-check + view-model refresh on every open, throttled inside
  `ClaudeStatusChecker`.
- **Right-click keeps a minimal fallback `NSMenu`** (About / Check for
  Updates… / Quit) — discoverability plus a guaranteed Quit path
  independent of SwiftUI.
- **Hotkeys are untouched.** ⌘⌥1–9 / ⌘⌥` are Carbon global hotkeys
  (`HotkeyManager`) and never depended on the menu.
- **The widget is *not* WidgetKit.** Swivel is ad-hoc signed; a WidgetKit
  appex wouldn't be trusted by the widget host. The `NSPanel` sits just
  above the desktop icons (visible on show-desktop, under app windows)
  with an "Always on Top" toggle to flip it to `.floating`; visibility,
  level, and frame persist across launches. A 60 s timer keeps the
  reset countdowns honest while it's visible (the usage reader's mtime
  cache makes idle ticks nearly free).

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

## Auto-update (Sparkle)

Swivel ≥ 1.1.0 ships with [Sparkle 2](https://sparkle-project.org)
wired up. The app polls
`https://raw.githubusercontent.com/jspanji/Swivel/main/appcast.xml`
on a 24-hour cadence (Sparkle's default) and offers any newer
release with a verified EdDSA signature. Users can also force a
check via **Check for Updates…** in the menu.

### One-time setup (maintainer only)

1. Download Sparkle's release tools so you have `generate_keys` and
   `sign_update` on your `PATH`. Easiest path:
   ```bash
   curl -L https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz \
     | tar -xJ -C /tmp
   sudo cp /tmp/bin/{generate_keys,sign_update} /usr/local/bin/
   ```
2. Generate the key pair. The private key lands in your login
   keychain; the tool prints the matching public key:
   ```bash
   generate_keys
   ```
3. Save the printed public key (one line of base64) to
   `sparkle.pubkey` at the repo root and commit it. The public key
   is meant to be public; only the private key is sensitive.
   ```bash
   echo "PUBLIC_KEY_HERE" > sparkle.pubkey
   git add sparkle.pubkey
   ```
4. Rebuild — `build-app.sh` will read the file and embed
   `SUPublicEDKey` into the bundle's `Info.plist`.

### Release process

1. Update `CHANGELOG.md`: move `[Unreleased]` items into a new
   `[X.Y.Z]` section, dated. Add a fresh empty `[Unreleased]`.
2. Build + sign:
   ```bash
   MARKETING_VERSION=X.Y.Z ./build-app.sh --release
   sign_update build/Swivel-X.Y.Z.zip
   ```
   `sign_update` prints a ready-to-paste `<enclosure …>` line.
3. Add a new `<item>` to the top of `appcast.xml` using that
   enclosure plus the version, pubDate, and a summary pulled from
   the CHANGELOG. Existing items stay below for older clients.
4. Commit: `appcast.xml`, `CHANGELOG.md`.
5. Tag and push:
   ```bash
   git tag -s vX.Y.Z -m "Swivel X.Y.Z"
   git push origin main --tags
   ```
6. The `release.yml` GitHub Action builds + zips + drafts a GitHub
   Release with the artifact attached. Review and **Publish** —
   that flips the asset to publicly downloadable, which the
   appcast's `enclosure url` is already pointing at.

The order matters: `appcast.xml` is committed *before* the release
asset exists at the URL. That's safe — Sparkle won't try to
download until users actually run a check, and by the time they do,
the published GitHub Release is live.

### Anatomy of an appcast item

```xml
<item>
    <title>Version 1.1.0</title>
    <pubDate>Wed, 23 Apr 2026 14:00:00 +0000</pubDate>
    <sparkle:version>2</sparkle:version>                      <!-- CFBundleVersion -->
    <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <description><![CDATA[
        - Auto-update via Sparkle.
        - Smart-switch nudge when active account approaches limit.
    ]]></description>
    <enclosure url="https://github.com/jspanji/Swivel/releases/download/v1.1.0/Swivel-1.1.0.zip"
               length="248192"
               type="application/octet-stream"
               sparkle:edSignature="…base64 sig from sign_update…" />
</item>
```

### Code signing & notarization

`build-app.sh` signs in one of two modes:

- **Developer ID** — used automatically when a
  `Developer ID Application` identity is in the keychain (or
  `SIGN_IDENTITY` is set). Adds `--options runtime` (hardened
  runtime) and `--timestamp`, both of which notarization requires.
- **Ad-hoc** — the fallback for dev/fork builds with no certificate.
  Runs locally; Gatekeeper warns on other Macs.

**Nested code is signed inside-out, never with `--deep`.** Apple
deprecates `--deep`, and it mis-signs Sparkle's nested bundles, which
notarization then rejects. The order is:

```
XPCServices/*.xpc → Updater.app → Autoupdate → Sparkle.framework → Swivel.app
```

**Notarization** runs via `--notarize` (or automatically inside
`--release` when `NOTARY_PROFILE` is set). One-time credential setup:

```
xcrun notarytool store-credentials "swivel-notary" \
    --apple-id <email> --team-id <TEAMID> --password <app-specific-password>
```

**Ordering is load-bearing:**

```
build → codesign → notarize → staple → zip → sign_update → appcast
```

Stapling rewrites the `.app`, so a zip produced before stapling would
ship an unstapled bundle *and* its Sparkle EdDSA signature and byte
length wouldn't match the artifact users download. `--release`
enforces this order.

Note that Sparkle's **EdDSA signing is separate** from Apple code
signing — a Developer ID does not replace `sign_update`; releases need
both. Verify a finished build with
`spctl -a -vvv -t install build/Swivel.app`, which should report
`source=Notarized Developer ID`.

## Live Usage (opt-in network path)

By default Swivel's only network call is the public status page. The
`LiveUsageClient` adds a second, **opt-in** path (`liveUsageEnabled`,
off by default, gated behind a confirmation dialog):

- For each account it decrypts the `sessionKey` + `lastActiveOrg`
  cookies from that profile's Chromium cookie store (Chromium v10
  scheme: PBKDF2-SHA1 of the device-local "Claude Safe Storage" key,
  AES-128-CBC, strip the 32-byte SHA256-domain prefix). This reuses the
  same Safe Storage key Swivel already reads to swap cookies on a
  switch — see `KeychainHelper`.
- It then `GET`s `https://claude.ai/api/organizations/<org>/usage` with
  that cookie and parses the `five_hour` / `seven_day` windows
  (`utilization` + `resets_at`) plus `extra_usage` (overage). This is the
  same data the claude.ai web app shows on its usage page. The plan tier
  comes from a second `GET .../organizations/<org>` (`rate_limit_tier`),
  cached for an hour since it changes rarely.
- Read-only, the user's own session, the user's own account. The
  decrypted cookie never leaves the process except as the `Cookie`
  header on that one request. Results are cached ~2 min per profile.
- Any failure (no cookie, expired session → 401, key mismatch after a
  Claude reinstall, offline) returns nil and the row falls back to the
  local `ProfileUsageReader` snapshot.

When the toggle is off, none of this runs and no cookie is ever read or
decrypted for usage purposes.

## Threat model

Covered in [SECURITY.md](../SECURITY.md). In brief, Swivel defends
against data loss from partial writes, silent corruption, and
concurrent switches. It does not defend against local adversaries with
access to your user account — that's the OS's job.

The opt-in Live Usage path (above) transmits each enabled account's
session cookie to claude.ai over HTTPS, and only to claude.ai. It is
off by default and requires explicit per-session-style consent; when
on, the trust boundary widens to include Anthropic's servers (which the
account already trusts by virtue of being a Claude session).
