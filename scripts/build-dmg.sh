#!/bin/bash
set -euo pipefail

# PowerMateReborn — Build & Package Script
# Usage: ./scripts/build-dmg.sh [--release]
#
# Builds the app and packages it into a .dmg for distribution.
# Pass --release for an optimized release build.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="PowerMateReborn"
BUILD_DIR="$PROJECT_DIR/build"
DMG_DIR="$BUILD_DIR/dmg-staging"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SIGN_IDENTITY="Developer ID Application: Eric Bintner (FU96NT58N5)"
ENTITLEMENTS="$PROJECT_DIR/PowerMateDriver.entitlements"
SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"

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

# Copy Sparkle Framework into bundle
echo "==> Embedding Sparkle.framework..."
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Generate Info.plist
VERSION="${POWERMATE_VERSION:-1.1.0}"
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
    <string>SiMfU+5TNl47TwuyIcSiH2bIxGIukFt0UEz9XMl5NiE=</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>PowerMateReborn uses Bluetooth to communicate with the Griffin PowerMate Bluetooth controller.</string>
</dict>
</plist>
PLIST

echo "    Version: $VERSION ($BUILD_NUMBER)"

# Strip extended attributes (resource forks, quarantine) that block codesign
echo "==> Stripping extended attributes..."
xattr -cr "$APP_BUNDLE"

# Code-sign the app bundle with Developer ID
echo "==> Code-signing with Developer ID..."

# Sign embedded frameworks first (inside-out signing)
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign --force --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
    codesign --force --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# Sign the main app bundle
if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
else
    codesign --force --options runtime \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
fi

# Verify signature
echo "    Verifying signature..."
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

# Sign the DMG with EdDSA for Sparkle
echo ""
if [[ -f "$SIGN_UPDATE" ]]; then
    echo "==> Signing DMG with EdDSA for Sparkle..."
    EDDSA_OUTPUT=$("$SIGN_UPDATE" "$DMG_PATH")
    echo "    $EDDSA_OUTPUT"
    echo ""
    echo "    Copy the above sparkle:edSignature and length into docs/appcast.xml"
else
    echo "    WARNING: sign_update not found. Run 'swift package resolve' to fetch Sparkle."
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
