#!/bin/bash
set -euo pipefail

# PowerMateReborn — Build & Package Script
# Usage: ./scripts/build-dmg.sh [--release]
#
# Builds the app and packages it into a .dmg for distribution.
# Pass --release for an optimized release build.
# Also notarizes the DMG (Gatekeeper requirement) using the stored
# notarytool keychain profile (NOTARY_PROFILE, default below), then prints
# the final Sparkle EdDSA signature. Set NOTARIZE=0 to skip notarization.
# Override the version with POWERMATE_VERSION=X.Y.Z.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="PowerMateReborn"
BUILD_DIR="$PROJECT_DIR/build"
DMG_DIR="$BUILD_DIR/dmg-staging"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SIGN_IDENTITY="Developer ID Application: Eric Bintner (FU96NT58N5)"
ENTITLEMENTS="$PROJECT_DIR/PowerMateDriver.entitlements"
SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
# Profile name given to `xcrun notarytool store-credentials "<name>"`
NOTARY_PROFILE="${NOTARY_PROFILE:-PowerMate-Notarization2}"

# Parse args
BUILD_CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
    BUILD_CONFIG="release"
fi

echo "==> Building $APP_NAME ($BUILD_CONFIG)..."

cd "$PROJECT_DIR"

if [[ "$BUILD_CONFIG" == "release" ]]; then
    swift build -c release
    BINARY_PATH=".build/release/PowerMateDriver"
else
    swift build
    BINARY_PATH=".build/debug/PowerMateDriver"
fi

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "ERROR: Binary not found at $BINARY_PATH"
    exit 1
fi

echo "==> Assembling .app bundle..."

# Clean previous build artifacts
rm -rf "$APP_BUNDLE" "$DMG_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy entitlements if present
if [[ -f "$PROJECT_DIR/PowerMateDriver.entitlements" ]]; then
    cp "$PROJECT_DIR/PowerMateDriver.entitlements" "$APP_BUNDLE/Contents/Resources/"
fi

# Copy resources (images, etc.)
if [[ -d "$PROJECT_DIR/Sources/Resources" ]]; then
    cp -R "$PROJECT_DIR/Sources/Resources/"* "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
fi

# Copy Sparkle Framework into bundle.
# Discover the framework wherever SwiftPM put it this time — the old hardcoded
# .build/artifacts path only exists after certain SwiftPM versions ran, and a
# missing framework produced the "Library not loaded: Sparkle" launch crash
# reported in issue #1.
echo "==> Embedding Sparkle.framework..."
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK="$(find "$PROJECT_DIR/.build" -type d -name "Sparkle.framework" -not -path "*/checkouts/*" 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_FRAMEWORK" || ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "ERROR: Sparkle.framework not found in SwiftPM build output. Run 'swift build' first."
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"

# Verify the framework's binary exists inside the copy and derive its version dir
SPARKLE_BINARY="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle"
if [[ ! -f "$SPARKLE_BINARY" ]]; then
    SPARKLE_BINARY="$(find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions" -type f -name Sparkle -print -quit 2>/dev/null)"
fi
if [[ -z "$SPARKLE_BINARY" || ! -f "$SPARKLE_BINARY" ]]; then
    echo "ERROR: Sparkle binary not found inside bundled framework"
    exit 1
fi
SPARKLE_VERSION="$(basename "$(dirname "$SPARKLE_BINARY")")"

# Rewrite the binary's Sparkle load command to point inside the bundle, and
# add the rpath. Fail loudly if the dependency can't be parsed — a silent
# skip ships the exact dyld crash reported in issue #1.
SPARKLE_DEP="$(otool -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep 'Sparkle.framework' | head -n 1 | awk '{print $1}')"
if [[ -z "$SPARKLE_DEP" ]]; then
    echo "ERROR: Sparkle framework dependency not found in binary's load commands"
    exit 1
fi
install_name_tool -change "$SPARKLE_DEP" \
    "@executable_path/../Frameworks/Sparkle.framework/Versions/$SPARKLE_VERSION/Sparkle" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Generate Info.plist
VERSION="${POWERMATE_VERSION:-1.2.0}"
BUILD_NUMBER="${POWERMATE_BUILD:-$(date +%Y%m%d%H%M)}"

cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.ericbintner.PowerMateReborn</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>PowerMateReborn</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2025 Eric Bintner. All rights reserved.</string>
    <key>SUFeedURL</key>
    <string>https://ericbintner.github.io/PowerMateReborn/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>SiMfU+5TNl47TWuyIcSiH2bIxGIukFt0UEz9XMl5NiE=</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>PowerMateReborn uses Bluetooth to communicate with the Griffin PowerMate Bluetooth controller.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>PowerMateReborn uses AppleScript to set system volume on devices without hardware volume control.</string>
</dict>
</plist>
PLIST

echo "    Version: $VERSION ($BUILD_NUMBER)"

# Guard against shipping a stale bundle: the packaged Info.plist must report
# the version this run was invoked with (the v1.1.0 release shipped a DMG that
# identified as v1.0.0 — see docs/RELEASE_PITFALLS.md).
PACKAGED_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$PACKAGED_VERSION" != "$VERSION" ]]; then
    echo "ERROR: packaged version ($PACKAGED_VERSION) != requested version ($VERSION) — refusing to ship a stale bundle"
    exit 1
fi

# Strip extended attributes (resource forks, quarantine) that block codesign
echo "==> Stripping extended attributes..."
xattr -cr "$APP_BUNDLE"

# Code-sign the app bundle with Developer ID
echo "==> Code-signing with Developer ID..."

# Sign embedded frameworks first (inside-out signing).
# Nested XPCs may not exist in every Sparkle build; sign the ones that do,
# but never mask a failure on the ones that do — a mismatched nested
# signature ships a "damaged app" to users.
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
    for NESTED in \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"; do
        if [[ -e "$NESTED" ]]; then
            codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$NESTED"
        fi
    done
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# Sign the main app bundle
if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
else
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
fi

# Verify signature — fail the build if the bundle doesn't verify
echo "    Verifying signature..."
codesign --verify --deep --strict "$APP_BUNDLE"
codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | grep -E "(Authority|TeamIdentifier|Signature)" || true

echo "==> Creating .dmg..."

DMG_NAME="${APP_NAME}_v${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# Create staging directory with app + Applications symlink
mkdir -p "$DMG_DIR"
cp -R "$APP_BUNDLE" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# Remove old dmg if it exists
rm -f "$DMG_PATH"

# Create DMG
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Clean up staging
rm -rf "$DMG_DIR"

# Notarize the DMG (Gatekeeper blocks un-notarized DMG-installed apps on
# modern macOS — the "can't be checked for malware" wall reported by issue #1
# users; see docs/RELEASE_PITFALLS.md Part 2 item 3). Requires the one-time
# `xcrun notarytool store-credentials "$NOTARY_PROFILE"` step from
# scripts/CODE_SIGNING.md. Skip deliberately with NOTARIZE=0.
if [[ "${NOTARIZE:-1}" != "0" ]]; then
    # Ask notarytool itself: current versions keep profiles where
    # `security find-generic-password` can't see them, so that check
    # reported real profiles as missing. This also validates the password.
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "==> Submitting DMG for notarization (2-5 min)..."
        if xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait; then
            echo "==> Stapling notarization ticket..."
            xcrun stapler staple "$DMG_PATH"
            xcrun stapler validate "$DMG_PATH"
        else
            echo "ERROR: notarization failed — DMG not notarized; do not publish."
            echo "       Inspect: xcrun notarytool log <id> --keychain-profile \"$NOTARY_PROFILE\""
            exit 1
        fi
    else
        echo "    WARNING: notary profile '$NOTARY_PROFILE' is missing or its password was rejected."
        echo "             Run scripts/CODE_SIGNING.md Step 2 (store-credentials), set NOTARY_PROFILE=<name>,"
        echo "             or re-run with NOTARIZE=0."
        exit 1
    fi
fi

# IMPORTANT: Sparkle's edSignature covers the exact DMG bytes. Notarization
# (stapling) is ticket-only and doesn't change the file, but sign_update
# above ran BEFORE notarization — regenerate the signature now so the
# appcast always covers the final artifact.
if [[ -f "$SIGN_UPDATE" ]]; then
    echo ""
    echo "==> Final Sparkle EdDSA signature (post-notarization)..."
    EDDSA_OUTPUT=$("$SIGN_UPDATE" "$DMG_PATH")
    echo "    $EDDSA_OUTPUT"
fi

echo ""
echo "==> Done!"
echo "    App:  $APP_BUNDLE"
echo "    DMG:  $DMG_PATH"
echo ""

# Print size
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
DMG_BYTES=$(wc -c < "$DMG_PATH" | tr -d ' ')
echo "    Size: $DMG_SIZE ($DMG_BYTES bytes)"
