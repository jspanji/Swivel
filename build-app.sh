#!/bin/bash
# Build Swivel as a proper .app bundle.
#
# Usage:
#   ./build-app.sh                    Build into ./build/Swivel.app
#   ./build-app.sh --install          Also copy into /Applications (replaces if present)
#   ./build-app.sh --notarize         Build + notarize + staple (needs NOTARY_PROFILE)
#   ./build-app.sh --release          Build [+ notarize] + zip + emit SHA-256
#
# Environment overrides:
#   MARKETING_VERSION=1.0.1           Override CFBundleShortVersionString (default: 1.1.0)
#   BUILD_NUMBER=42                   Override CFBundleVersion (default: git rev count, or 1)
#   SIGN_IDENTITY="Developer ID Application: …"
#                                     Signing identity. Auto-detected from the
#                                     keychain; falls back to ad-hoc if absent.
#   NOTARY_PROFILE=swivel-notary      notarytool keychain profile. When set,
#                                     --release notarizes + staples before zipping.
#   NOTARY_KEYCHAIN=/path/to.keychain-db
#                                     Keychain holding that profile. Only needed
#                                     when it isn't the default keychain (CI
#                                     stores it in an ephemeral one).

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Swivel"
BUNDLE_ID="com.joes.swivel"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"

# Version metadata. Marketing version is a human-readable semver string
# surfaced in the About dialog. Build number should monotonically increase
# per build — git rev-count is a sensible default when available.
MARKETING_VERSION="${MARKETING_VERSION:-1.1.0}"
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    if git rev-parse --git-dir >/dev/null 2>&1; then
        BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
    else
        BUILD_NUMBER="1"
    fi
fi

echo "==> Compiling Swivel ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
swift build -c release

# Sparkle auto-update wiring. The public EdDSA key is committed at
# `sparkle.pubkey` (it's public; only the private key in the
# maintainer's keychain is sensitive). If the file is missing the
# build still succeeds, but Sparkle won't be able to verify any
# update — useful for fork/dev builds, not for releases.
SPARKLE_FEED_URL="https://raw.githubusercontent.com/jspanji/Swivel/main/appcast.xml"
SPARKLE_PUBLIC_KEY=""
if [[ -f sparkle.pubkey ]]; then
    SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < sparkle.pubkey)"
elif [[ -n "${SPARKLE_PUBLIC_KEY_OVERRIDE:-}" ]]; then
    SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY_OVERRIDE}"
fi
if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "    (note: no sparkle.pubkey — auto-update will be installed but unable to verify signatures)"
fi

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Build failed: $BIN_PATH not found" >&2
    exit 1
fi

echo "==> Assembling ${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"

# App icon. Without this the bundle has no icon at all and Finder shows the
# generic blank-application placeholder — in the DMG, in /Applications, and
# in Open With. Regenerate with: swift Resources/icon-render.swift && \
#   iconutil -c icns Swivel.iconset -o Resources/Swivel.icns
if [[ -f Resources/${APP_NAME}.icns ]]; then
    cp "Resources/${APP_NAME}.icns" "$APP_DIR/Contents/Resources/${APP_NAME}.icns"
else
    echo "    (note: Resources/${APP_NAME}.icns missing — app will have no icon)"
fi

# Sparkle ships its bundled XPC services + auto-update UI inside its
# .framework — has to live under Frameworks/ for the dynamic loader
# and Sparkle's `Autoupdate` helper to find it. Source path is the
# universal xcframework slice that ships in the SPM artifact bundle;
# Sparkle's docs confirm copying just the macOS slice is correct.
SPARKLE_SRC="$(swift build -c release --show-bin-path)/Sparkle.framework"
if [[ ! -d "$SPARKLE_SRC" ]]; then
    SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [[ ! -d "$SPARKLE_SRC" ]]; then
    echo "Sparkle.framework not found — did you run 'swift build' first?" >&2
    exit 1
fi
cp -R "$SPARKLE_SRC" "$APP_DIR/Contents/Frameworks/"

# SPM's executable targets don't set the standard macOS app rpath
# pointing at Contents/Frameworks/, so dyld can't find Sparkle at
# launch ("Library not loaded: @rpath/Sparkle.framework/..."). Patch
# the binary in place — has to happen BEFORE codesign because adding
# an rpath invalidates any signature already on the binary.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_DIR/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

YEAR="$(date +%Y)"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © ${YEAR} Swivel contributors. MIT License.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# Code signing
#
# Two modes:
#   Developer ID  — when SIGN_IDENTITY is set (or a Developer ID Application
#                   identity is found in the keychain). Adds the hardened
#                   runtime + secure timestamp, which notarization REQUIRES.
#   Ad-hoc        — fallback. Runs fine locally; Gatekeeper warns on other
#                   Macs. This is what dev/fork builds get for free.
#
# Nested code is signed INSIDE-OUT (deepest first), not with `--deep`.
# Apple deprecates `--deep`, and it signs Sparkle's XPC services and
# Updater.app incorrectly — notarization rejects the result.
# ---------------------------------------------------------------------------
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    # Auto-detect a Developer ID Application identity; empty if none.
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

SPARKLE_FW="$APP_DIR/Contents/Frameworks/Sparkle.framework"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing with: $SIGN_IDENTITY"
    SIGN_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")

    # Inside-out: XPC services → Updater.app → Autoupdate → framework → app.
    for xpc in "$SPARKLE_FW/Versions/B/XPCServices/"*.xpc; do
        [[ -e "$xpc" ]] || continue
        codesign "${SIGN_FLAGS[@]}" "$xpc"
    done
    [[ -e "$SPARKLE_FW/Versions/B/Updater.app" ]] && \
        codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW/Versions/B/Updater.app"
    [[ -e "$SPARKLE_FW/Versions/B/Autoupdate" ]] && \
        codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE_FW"
    codesign "${SIGN_FLAGS[@]}" "$APP_DIR"

    codesign --verify --strict --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/    /'
else
    # Ad-hoc: `--deep` is acceptable here because nothing is notarized and
    # the signature only needs to satisfy the local loader.
    echo "==> Signing ad-hoc (no Developer ID identity found)"
    echo "    Set SIGN_IDENTITY, or install a Developer ID Application cert,"
    echo "    to produce a distributable build."
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "==> Built: $APP_DIR"

case "${1:-}" in
    --install)
        DEST="/Applications/${APP_NAME}.app"
        if [[ -e "$DEST" ]]; then
            echo "==> Replacing $DEST"
            rm -rf "$DEST"
        fi
        cp -R "$APP_DIR" "$DEST"
        echo "==> Installed to $DEST"
        echo "Launch with: open \"$DEST\""
        ;;

    --notarize | --release)
        # Notarize + staple BEFORE zipping, when a notary profile is
        # configured. Order matters: stapling rewrites the .app, so a zip
        # made beforehand would ship an unstapled bundle (and its Sparkle
        # EdDSA signature + byte length wouldn't match the final artifact).
        #
        #   Build → codesign → notarize → staple → zip → sign_update → appcast
        #
        # Set up credentials once with:
        #   xcrun notarytool store-credentials "swivel-notary" \
        #       --apple-id <email> --team-id <TEAMID> --password <app-specific>
        if [[ -n "${NOTARY_PROFILE:-}" ]]; then
            if [[ -z "$SIGN_IDENTITY" ]]; then
                echo "Refusing to notarize an ad-hoc signed app — set SIGN_IDENTITY." >&2
                exit 1
            fi
            NOTARIZE_ZIP="$BUILD_DIR/${APP_NAME}-notarize.zip"
            echo "==> Submitting to Apple notary service (this can take a few minutes)"
            ditto -c -k --keepParent "$APP_DIR" "$NOTARIZE_ZIP"
            NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
            [[ -n "${NOTARY_KEYCHAIN:-}" ]] && NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
            xcrun notarytool submit "$NOTARIZE_ZIP" "${NOTARY_ARGS[@]}" --wait
            rm -f "$NOTARIZE_ZIP"
            echo "==> Stapling ticket"
            xcrun stapler staple "$APP_DIR"
            spctl -a -vvv -t install "$APP_DIR" 2>&1 | sed 's/^/    /'
        elif [[ "${1:-}" == "--notarize" ]]; then
            echo "NOTARY_PROFILE is not set — nothing to submit." >&2
            echo "See the comment above this block for the one-time setup." >&2
            exit 1
        fi

        # --notarize stops here; --release continues on to package the zip.
        [[ "${1:-}" == "--notarize" ]] && exit 0

        # Produce a distributable zip + SHA-256 suitable for attaching
        # to a GitHub release. The zip is what Sparkle's appcast points at.
        ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"
        ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
        (cd "$BUILD_DIR" && ditto -c -k --keepParent "${APP_NAME}.app" "$ZIP_NAME")
        SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

        # A .dmg alongside it — the nicer human download: mounts to a window
        # with the app and a drag-target alias to /Applications. Built from
        # the already-stapled .app, so the copy the user drags out carries its
        # own notarization ticket.
        DMG_NAME="${APP_NAME}-${MARKETING_VERSION}.dmg"
        DMG_PATH="$BUILD_DIR/$DMG_NAME"
        rm -f "$DMG_PATH"
        scripts/make-dmg.sh "$APP_DIR" "$DMG_PATH" "${APP_NAME}"

        # The disk image is a separate signable/notarizable artifact from the
        # app inside it. Sign + notarize it too, or downloading the .dmg
        # itself trips Gatekeeper even though the app within is clean.
        if [[ -n "$SIGN_IDENTITY" ]]; then
            codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
        fi
        if [[ -n "${NOTARY_PROFILE:-}" && -n "$SIGN_IDENTITY" ]]; then
            echo "==> Notarizing $DMG_NAME"
            DMG_NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
            [[ -n "${NOTARY_KEYCHAIN:-}" ]] && DMG_NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
            xcrun notarytool submit "$DMG_PATH" "${DMG_NOTARY_ARGS[@]}" --wait
            xcrun stapler staple "$DMG_PATH"
        fi
        DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
        echo ""
        echo "==> Release artifacts"
        echo "     Zip:    $ZIP_PATH"
        echo "     SHA256: $SHA"
        echo "     DMG:    $DMG_PATH"
        echo "     SHA256: $DMG_SHA"
        echo ""
        echo "Attach the zip to your GitHub release and paste the SHA-256"
        echo "into the release notes so users can verify the download."
        ;;

    "")
        echo "To install: ./build-app.sh --install"
        echo "To run locally: open \"$APP_DIR\""
        echo "To make a release zip: ./build-app.sh --release"
        ;;

    *)
        echo "Unknown option: $1" >&2
        echo "Usage: $0 [--install | --release]" >&2
        exit 2
        ;;
esac
