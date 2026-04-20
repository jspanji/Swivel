#!/bin/bash
# Build Swivel as a proper .app bundle.
#
# Usage:
#   ./build-app.sh                    Build into ./build/Swivel.app
#   ./build-app.sh --install          Also copy into /Applications (replaces if present)
#   ./build-app.sh --release          Build + zip + emit SHA-256 for GitHub releases
#
# Environment overrides:
#   MARKETING_VERSION=1.0.1           Override CFBundleShortVersionString (default: 1.0.0)
#   BUILD_NUMBER=42                   Override CFBundleVersion (default: git rev count, or 1)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Swivel"
BUNDLE_ID="com.joes.swivel"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"

# Version metadata. Marketing version is a human-readable semver string
# surfaced in the About dialog. Build number should monotonically increase
# per build — git rev-count is a sensible default when available.
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    if git rev-parse --git-dir >/dev/null 2>&1; then
        BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
    else
        BUILD_NUMBER="1"
    fi
fi

echo "==> Compiling Swivel ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Build failed: $BIN_PATH not found" >&2
    exit 1
fi

echo "==> Assembling ${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/${APP_NAME}"

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
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will actually run it without Gatekeeper whining.
# For distribution outside your own machine, re-sign with a Developer ID
# and notarize — see docs/ARCHITECTURE.md.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

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

    --release)
        # Produce a distributable zip + SHA-256 suitable for attaching
        # to a GitHub release.
        ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"
        ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
        (cd "$BUILD_DIR" && ditto -c -k --keepParent "${APP_NAME}.app" "$ZIP_NAME")
        SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
        echo ""
        echo "==> Release artifact"
        echo "     File:   $ZIP_PATH"
        echo "     SHA256: $SHA"
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
