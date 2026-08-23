#!/bin/bash
# Build a styled .dmg: background art, fixed icon positions, custom volume
# icon, no toolbar.
#
#   scripts/make-dmg.sh <App.app> <output.dmg> <VolumeName>
#
# The layout lives in the volume's .DS_Store, which normally only Finder can
# write — and driving Finder needs Automation permission plus a real desktop
# session, which headless CI runners don't have.
#
# So the layout is baked ONCE into a committed template
# (Resources/dmg/dmg-DS_Store) and copied in on every build. That makes the
# output deterministic and identical locally and in CI, rather than styled on
# a developer's Mac and plain from a runner.
#
# To change the layout, re-record the template:
#     RESTYLE=1 scripts/make-dmg.sh <App.app> <out.dmg> Swivel
# which drives Finder once and writes the result back over the template.
set -euo pipefail

APP="$1"; OUT="$2"; VOL="${3:-Swivel}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BG_1X="$REPO_ROOT/Resources/dmg/background.png"
BG_2X="$REPO_ROOT/Resources/dmg/background@2x.png"
ICNS_SRC="$REPO_ROOT/Resources/Swivel.icns"
# Committed under a non-dot name: .gitignore blocks ".DS_Store" everywhere.
DS_TEMPLATE="$REPO_ROOT/Resources/dmg/dmg-DS_Store"

WORK="$(mktemp -d)"; RW="$WORK/rw.dmg"
# Detach too: a failure between attach and detach would otherwise leave
# /Volumes/$VOL mounted and confuse the next run.
cleanup() {
    hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Combine the 1x/2x PNGs into a HiDPI TIFF here rather than committing the
# derived file — one source of truth, and it can't drift from the PNGs.
if [[ -f "$BG_1X" && -f "$BG_2X" ]]; then
    tiffutil -cathidpicheck "$BG_1X" "$BG_2X" \
        -out "$STAGE/.background/background.tiff" >/dev/null 2>&1 \
        || cp "$BG_1X" "$STAGE/.background/background.tiff"
fi

# Read-write image, sized with headroom so Finder can write its .DS_Store.
SIZE_KB=$(( $(du -sk "$STAGE" | awk '{print $1}') + 20000 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
    -format UDRW -size "${SIZE_KB}k" "$RW" >/dev/null

MOUNT="/Volumes/$VOL"
hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
hdiutil attach "$RW" -noautoopen -quiet
sync

# Layout: copy the recorded template unless we're explicitly re-recording.
if [[ "${RESTYLE:-0}" != "1" && -f "$DS_TEMPLATE" ]]; then
    cp "$DS_TEMPLATE" "$MOUNT/.DS_Store"
    echo "    layout from template (deterministic, CI-safe)"
elif osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        try
            set pathbar visible of container window to false
        end try
        set sidebar width of container window to 0
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 12
        try
            set background picture of opts to file ".background:background.tiff"
        end try
        set position of item "$(basename "$APP")" of container window to {165, 205}
        set position of item "Applications" of container window to {495, 205}
        -- Park the support files far below the 400pt viewport so anyone with
        -- AppleShowAllFiles enabled sees only the two real icons up front.
        repeat with hidden_name in {".background", ".fseventsd", ".VolumeIcon.icns", ".Trashes"}
            try
                set position of item hidden_name of container window to {165, 820}
            end try
        end repeat
        -- Bounds LAST and without a close/reopen: reopening lets Finder
        -- restore a remembered size.
        set the bounds of container window to {200, 120, 860, 520}
        update without registering applications
        delay 2
        set the bounds of container window to {200, 120, 860, 520}
        close
    end tell
end tell
APPLESCRIPT
then
    echo "    styled via Finder"
    sync
    if [[ -f "$MOUNT/.DS_Store" ]]; then
        cp "$MOUNT/.DS_Store" "$DS_TEMPLATE"
        echo "    template re-recorded → ${DS_TEMPLATE#$REPO_ROOT/}"
    fi
else
    echo "    (note: no template and Finder unavailable — plain DMG layout)"
fi

# Volume icon. Copy it onto the MOUNTED volume rather than into the staging
# folder — a root-level .VolumeIcon.icns doesn't reliably survive
# `hdiutil create -srcfolder`. The `C` attribute is what tells Finder to use
# it instead of the generic disk icon.
if [[ -f "$ICNS_SRC" ]]; then
    cp "$ICNS_SRC" "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT" 2>/dev/null || echo "    (note: SetFile unavailable — generic volume icon)"
fi

# Belt-and-braces hiding: dotfiles are hidden by default, but anyone with
# `AppleShowAllFiles` on would otherwise see .background / .fseventsd sitting
# in the install window. The invisible bit hides them regardless.
SetFile -a V "$MOUNT/.background" 2>/dev/null || true
SetFile -a V "$MOUNT/.fseventsd" 2>/dev/null || true
SetFile -a V "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
rm -rf "$MOUNT/.Trashes" 2>/dev/null || true

chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
