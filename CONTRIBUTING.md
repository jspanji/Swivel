# Contributing to Swivel

Thanks for considering a contribution. This document covers how to
propose changes, what the bar is for code quality, and how to run the
app locally.

## Ground rules

- **Be kind.** Assume good intent. Disagreements happen; keep them
  about the code.
- **One change per PR.** A refactor + a feature + a bug fix in one
  branch is hard to review and risky to revert.
- **Include tests or a manual test plan.** There's no test suite yet,
  so a clear "I verified by doing X, Y, Z" in the PR body is
  mandatory.

## Development setup

Requirements:

- macOS 13 Ventura or later
- Swift 5.9+ (Xcode 15 or [swift.org](https://www.swift.org/download/))
- Claude Desktop installed and launched at least once

Build and run:

```bash
git clone https://github.com/jspanji/Swivel.git
cd Swivel
swift build                    # debug build
swift run                      # run the debug binary
./build-app.sh                 # bundle into ./build/Swivel.app
./build-app.sh --install       # copy into /Applications
```

> ⚠️ **Back up your accounts before testing.** Swivel works with your
> real Claude session data. Before running development builds, save
> your account(s) with a release build first; if something breaks, the
> release build's snapshots are still recoverable.

## Project structure

| Path | Responsibility |
|------|----------------|
| `Sources/Swivel/main.swift` | App entry point |
| `Sources/Swivel/AppDelegate.swift` | Menu bar lifecycle, hotkeys, UI actions |
| `Sources/Swivel/SwitchCoordinator.swift` | Serializes switches, background dispatch |
| `Sources/Swivel/ProfileManager.swift` | Snapshot/restore, manifest, backups, keychain |
| `Sources/Swivel/MenuBuilder.swift` | Menu composition, palette, swatches |
| `Sources/Swivel/ClaudeAppController.swift` | Quit/launch Claude Desktop |
| `Sources/Swivel/ClaudeStatusChecker.swift` | Polls status.claude.com |
| `Sources/Swivel/KeychainHelper.swift` | Reads `Claude Safe Storage` |
| `Sources/Swivel/HotkeyManager.swift` | Carbon global hotkeys |
| `Sources/Swivel/LoginItemManager.swift` | `SMAppService` wrapper |
| `docs/ARCHITECTURE.md` | Design doc — read before touching snapshot internals |

## Code style

- Prefer clarity over cleverness. If a comment would help, write the
  comment.
- Match the surrounding file. Don't reformat code you're not changing.
- Public-ish types get a documentation comment (`///`). Implementation
  details get regular `//` comments that explain *why*, not *what*.
- Use `os.Logger` (not `print`) for diagnostic output. The existing
  subsystem is `com.swivel.app`.

## The bar for PRs

Before opening a PR, self-check:

- [ ] `swift build` is clean — no warnings, no errors.
- [ ] If the change affects snapshot/restore or the switch flow, I've
  run through: save, switch, save, restore-backup, delete, rename,
  color-change, and launch-at-login flows by hand.
- [ ] The CHANGELOG's `[Unreleased]` section has an entry describing
  the user-visible change (or I've explained why it doesn't need one).
- [ ] If it's a breaking change to the on-disk format under
  `~/Library/Application Support/Swivel/`, there's a migration path
  and I've documented it.
- [ ] If the change touches security-relevant code (atomic promotion,
  keychain, manifest), the PR description walks through the threat
  model.

## Areas where help is particularly welcome

- A unit test target. `ProfileManager`'s snapshot/restore flows are
  purely file I/O — a fake `FileManager` or a tmp-dir-based test
  harness would make this directly testable.
- Sparkle integration for auto-updates (the build script already
  emits versioned binaries; wiring Sparkle + an appcast is mostly
  config).
- A homebrew tap formula.
- Accessibility polish. Swatches should carry VoiceOver descriptions;
  status indicators should announce changes.

## Reporting bugs

Use the bug-report issue template. Please include:

- Swivel version from the About dialog.
- macOS version.
- The exact sequence of actions that reproduces the issue.
- Relevant output from Console.app filtered by `subsystem:com.swivel.app`.

Security issues: follow [SECURITY.md](SECURITY.md) — do not file
them publicly.

## Release process

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#release-process).

## License

By contributing, you agree that your contributions will be licensed
under the MIT License (see [LICENSE](LICENSE)).
