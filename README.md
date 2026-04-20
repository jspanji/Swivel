# Swivel

**Switch between Claude Desktop accounts in two seconds. No more logging out.**

[![CI](https://github.com/jspanji/Swivel/actions/workflows/ci.yml/badge.svg)](https://github.com/jspanji/Swivel/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/jspanji/Swivel?include_prereleases&sort=semver)](https://github.com/jspanji/Swivel/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/swift-5.9%2B-orange?logo=swift)](https://www.swift.org/)

Swivel lives in your menu bar. Each account gets a saved snapshot of Claude Desktop's session — cookies, auth, chat history, preferences. Bind accounts to `⌘⌥1`, `⌘⌥2`, …, and flip between Personal ↔ Work (or Client A ↔ Client B) without logging out.

> Everything runs locally. No telemetry. The only network request is to the public [Claude status page](https://status.claude.com) for the menu bar's service-status indicator.

<!-- Drop a screenshot or short GIF here once you have one -->
<!-- <p align="center"><img src="docs/screenshot.png" width="520" alt="Swivel menu screenshot"></p> -->

## Why

Juggling two Claude accounts — personal + work, or a couple of client logins — means signing out and back in. That kills your side panel, your conversation drafts, your MCP settings, and sometimes prompts the keychain. Swivel captures the entire Claude Desktop profile per account and swaps them atomically with a keyboard shortcut.

## Install

### Download the release

Grab `Swivel-<version>.zip` from the [latest release](https://github.com/jspanji/Swivel/releases/latest). Unzip, drag `Swivel.app` to `/Applications`, and launch it.

> First launch: macOS will warn that the app is from an unidentified developer (ad-hoc signed). Right-click the app and choose **Open** → **Open**. You only need to do this once.

### Build from source

Requires macOS 13+ and Swift 5.9+ (Xcode 15 or a standalone Swift toolchain).

```bash
git clone https://github.com/jspanji/Swivel.git
cd Swivel
./build-app.sh --install
open /Applications/Swivel.app
```

## Setup

1. Sign into your first Claude account in Claude Desktop.
2. Menu bar icon → **Add Account…** → name it (e.g. *Personal*).
3. Sign out. Sign into your second account.
4. **Add Account…** → *Work*.

You now have two accounts. **Press `⌘⌥1` or `⌘⌥2`** to switch — or click the menu bar icon and pick one. Claude quits, the session swaps, Claude relaunches. The round trip is usually under two seconds.

## Shortcuts

| Shortcut      | Action                                |
|---------------|---------------------------------------|
| `⌘⌥1` … `⌘⌥9` | Switch to account by slot             |
| `` ⌘⌥` ``     | Flip back to the previous account     |

Slots follow the order accounts appear in the menu (alphabetical). Open the menu to see the current mapping — the shortcut is shown next to each account name.

## The menu

- **Account list** — click any account to switch. The active account is bold.
- **Last used** — a persistent "flip back" row. Faster than re-picking.
- **Update \<Account\>** — refresh the saved snapshot of the *current* account from Claude's live state. Run this occasionally to keep your saved profile in sync with recent chats.
- **Add Account…** — save the current Claude session as a new account.
- **Manage ▸ \<Account\>** — rename, change color, restore a backup, or delete.
- **Launch at Login** — start Swivel automatically at boot.
- **Help & Documentation** — opens this README in the browser.

Each account gets a colored menu bar icon so you can see which one is active at a glance. Pick the color under **Manage ▸ \<Account\> ▸ Change Color**.

## Backups

Every save and every switch rotates the prior snapshot into a timestamped backup. Swivel keeps the **most recent 3 backups per account**.

Restore one from **Manage ▸ \<Account\> ▸ Restore Backup**. The current snapshot becomes a new backup first, so you can undo the undo.

Snapshots are integrity-checked with a SHA-256 manifest. If a saved profile is ever corrupted (partial crash, disk error), Swivel refuses to restore it and surfaces the problem instead of silently propagating it to your live Claude install. Full design in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Troubleshooting

<details>
<summary><strong>"Switch failed: Profile's saved safeStorage key differs…"</strong></summary>

You reinstalled Claude Desktop, which generated a new local encryption key. The previously-saved cookies can no longer be decrypted.

**Fix:** re-save the affected account from a logged-in Claude session. **Add Account…** with the same name overwrites.
</details>

<details>
<summary><strong>"Switch failed: Profile snapshot integrity check failed…"</strong></summary>

The snapshot's manifest doesn't match its files — usually from disk corruption or a mid-snapshot crash.

**Fix:** restore a backup via **Manage ▸ \<Account\> ▸ Restore Backup**. Or re-save the account from a logged-in session.
</details>

<details>
<summary><strong>Keychain prompts on every switch</strong></summary>

The first save of each account reads the Claude keychain key. If you didn't click **Always Allow** at that prompt, every subsequent read re-prompts.

**Fix:** delete the account and re-add it, clicking *Always Allow* this time. Swivel does not modify the keychain on switch — so once you've approved once, switches are silent.
</details>

<details>
<summary><strong>"Launch at Login" won't toggle on</strong></summary>

Launch-at-login requires the app to live in `/Applications`.

**Fix:** run `./build-app.sh --install` rather than launching from the `build/` folder.
</details>

<details>
<summary><strong>Hotkeys don't fire</strong></summary>

macOS may ask for Accessibility or Input Monitoring permission on first launch.

**Fix:** grant it in **System Settings → Privacy & Security → Accessibility**.
</details>

<details>
<summary><strong>Gatekeeper says "Swivel.app can't be opened"</strong></summary>

The release binary is ad-hoc signed, not notarized.

**Fix:** right-click the app in Finder and choose **Open** → **Open**. You'll only need to do this once per install.
</details>

## How it works

Claude Desktop stores session data in `~/Library/Application Support/Claude/` and encrypts its cookie store with a Keychain entry (`Claude Safe Storage` / `Claude Key`).

On **save**, Swivel:
1. Reads the keychain key once — the only keychain interaction (the key is device-local and never rotates).
2. Copies the Claude folder and preferences plist into a staging directory.
3. Writes a SHA-256 manifest of every file as the "stage complete" marker.
4. Atomically promotes the staged directory over the profile via APFS `renamex_np` — a kernel-level atomic swap. A crash at any point during a save leaves either the old or new snapshot intact, never a partial merge.

On **switch**, Swivel:
1. Quits Claude and waits for it to fully exit.
2. Snapshots the current session back to the active account (so no state is lost).
3. Verifies the target account's manifest against its on-disk files.
4. Restores the target snapshot into Claude's Application Support directory.
5. Relaunches Claude.

Claude Code CLI state (`claude-code*` folders) is deliberately left in place — your terminal sessions aren't tied to the GUI account.

Full internals in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requirements

- macOS 13 (Ventura) or later
- Claude Desktop (launched at least once, so the Application Support directory exists)
- Swift 5.9+ for building from source

## Limitations

- Don't edit Claude Desktop while a switch is in progress. The menu bar icon dims while work is in flight — wait for it to brighten.
- Keychain key rotation (rare — happens when Claude Desktop is fully reinstalled) invalidates saved cookies. Affected accounts must be re-saved.
- Release builds are ad-hoc signed, not notarized. First launch requires a right-click → Open.
- This is an unofficial tool. It's not affiliated with Anthropic.

## Uninstall

Quit Swivel, then:

```bash
rm -rf /Applications/Swivel.app
rm -rf ~/Library/Application\ Support/Swivel
```

Your Claude Desktop sessions stay where they are — uninstalling Swivel doesn't touch them.

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the setup and the bar. The design doc is [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — start there if you're touching snapshot or switch internals.

## Security

Swivel touches authentication state. If you find a vulnerability, please report it privately via the [Security tab](https://github.com/jspanji/Swivel/security/advisories/new) — not a public issue. Full policy and threat model in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Unofficial tool, not affiliated with Anthropic.
