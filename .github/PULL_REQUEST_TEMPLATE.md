<!--
Thanks for the PR! A few asks:
  1. One change per PR. Refactor + feature + fix in one branch is hard to review.
  2. Fill in every section below. "N/A" is fine where it applies.
  3. Link the issue this PR addresses, if any.
-->

## Summary

<!-- One or two sentences on what this PR does and why. -->

## What changed

- <!-- Bullet each user-visible or architectural change. -->

## Test plan

<!--
There's no test suite yet, so describe exactly what you did by hand.
List the flows you walked through. Don't just say "it works."
-->

- [ ] `swift build` is clean (no warnings, no errors)
- [ ] Saved a new account; verified the snapshot appeared under `~/Library/Application Support/Swivel/profiles/`
- [ ] Switched between two accounts via `⌘⌥1` / `⌘⌥2`; both sessions restored correctly
- [ ] Restored a backup from Manage ▸ Restore Backup; verified the "undo the undo" backup was created
- [ ] Other: <!-- list flows specific to this change -->

## Screenshots / recordings

<!-- Drag images or short MP4/GIF clips in here if the change is UI-visible. -->

## Related

<!-- Fixes #123, Closes #456, Refs #789 -->

## Checklist

- [ ] `CHANGELOG.md` updated under `[Unreleased]` (or marked N/A below)
- [ ] If this changes on-disk format under `~/Library/Application Support/Swivel/`, migration is handled
- [ ] If this touches snapshot/restore or the switch flow, I've read `docs/ARCHITECTURE.md`
- [ ] If this touches security-relevant code, the threat-model implications are called out above
