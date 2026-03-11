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

# Generate Info.plist
VERSION="${POWERMATE_VERSION:-1.0.0}"
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
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2025 Eric Bintner. All rights reserved.</string>
    <key>SUFeedURL</key>
    <string>https://ericbintner.github.io/PowerMateReborn/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>REPLACE_WITH_YOUR_EDDSA_PUBLIC_KEY</string>
</dict>
</plist>
PLIST

echo "    Version: $VERSION ($BUILD_NUMBER)"

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

echo ""
echo "==> Done!"
echo "    App:  $APP_BUNDLE"
echo "    DMG:  $DMG_PATH"
echo ""

# Print size
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo "    Size: $DMG_SIZE"

# Reminder about signing
if ! codesign -dv "$APP_BUNDLE" 2>/dev/null; then
    echo ""
    echo "    NOTE: App is NOT code-signed. To sign and notarize:"
    echo "    codesign --deep --force --options runtime --sign \"Developer ID Application: YOUR NAME\" $APP_BUNDLE"
    echo "    xcrun notarytool submit $DMG_PATH --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password YOUR_APP_PASSWORD"
fi
