# Security

Swivel touches authentication state. This document describes the threat
model, how to report vulnerabilities, and what guarantees Swivel does and
does not make.

## Reporting a vulnerability

**Please do not file a public GitHub issue for security problems.**

Instead, open a private report via GitHub Security Advisories:

> Repository → **Security** tab → **Report a vulnerability**

If that's unavailable, email the maintainer listed in the repository's
`CODEOWNERS` or top-level `README.md`. Acknowledgement within 72 hours.
Please include:

- A description of the issue and its impact.
- Steps to reproduce.
- Swivel version (`About Swivel` → version string).
- macOS version.

We will coordinate a fix, a release, and a disclosure date with you.
Credit in the release notes unless you'd prefer anonymity.

## What Swivel touches

1. **Claude Desktop session files** at
   `~/Library/Application Support/Claude/`. These include cookies,
   IndexedDB, local storage, and cached chat history.
2. **The Claude Desktop preferences plist** at
   `~/Library/Preferences/com.anthropic.claudefordesktop.plist`.
3. **One keychain item** — `Claude Safe Storage` / `Claude Key`. Swivel
   reads this once per account at first save to verify it still matches
   on later switches. Swivel never writes to the keychain.
4. **Its own state** at `~/Library/Application Support/Swivel/`
   (profile snapshots, backups, `state.json`).

Everything above stays on the local machine. Swivel makes no network
requests except to `https://status.claude.com` for the service-status
indicator.

## Threat model

Swivel defends against:

- **Data loss from partial writes.** Snapshots are built in a staging
  directory and atomically promoted via `renamex_np` with `RENAME_SWAP`
  (backing `FileManager.replaceItemAt` on APFS). A crash or power loss
  leaves either the old or new snapshot intact, never a half-merged
  directory.
- **Silent corruption.** Every snapshot embeds a SHA-256 manifest.
  Restores re-hash the snapshot and refuse to touch the live Claude
  install if anything fails to verify.
- **Concurrent switches.** The switch coordinator serializes swaps.
  Rapid hotkey presses beep instead of queuing overlapping operations.
- **Keychain prompt fatigue.** Swivel reads the keychain key once per
  account at first save and never rewrites the keychain entry (doing so
  would strip Claude's `teamid:` from the item's partition list and
  cause Claude itself to prompt on every launch).

Swivel does **not** defend against:

- **Local root attackers.** Anyone with your user account can read
  `~/Library/Application Support/Claude/` directly. Swivel provides no
  additional encryption — it relies on macOS's existing file permissions
  and FileVault (if enabled).
- **Malware running as your user.** Same as above.
- **Physical attackers with an unlocked Mac.**

## Profile snapshot file permissions

- Snapshot directories: inherit umask (typically 700 or 755 depending on
  your system).
- `safe_storage.key` (per-profile keychain key copy): mode `0600`,
  explicitly set after write.
- `state.json` (active/previous pointers, color map): mode 644 via
  atomic write.

If you operate in a shared-home-directory environment, consider tightening
the mode on `~/Library/Application Support/Swivel/` to `0700`:

```bash
chmod 700 ~/Library/Application\ Support/Swivel
```

## Known limitations

- **Ad-hoc signed binaries** from `./build-app.sh` are not notarized.
  Distribution outside your own machine will trigger Gatekeeper warnings
  on first launch. For wider distribution, re-sign with a Developer ID
  certificate and notarize.
- **The keychain key is held briefly in a Swift `String`** when it's
  first read from the keychain. Swift Strings cannot be explicitly
  zeroed in memory; the key could theoretically be recovered from a
  core dump before the string is deallocated. macOS's keychain already
  stores the same value in (encrypted) form, so this is a marginal
  exposure.

## Supported versions

Only the latest `1.x` release is supported with security updates.
Older versions should upgrade before filing reports.

| Version | Supported |
|---------|-----------|
| 1.0.x   | ✅         |
| < 1.0   | ❌ (pre-release) |
