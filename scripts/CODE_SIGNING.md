# Code Signing & Notarization Guide

## Why You Need This

Without code signing, users get a scary "unidentified developer" Gatekeeper warning and must right-click > Open. With signing + notarization, the app installs and launches cleanly like any App Store app.

## Prerequisites

1. **Apple Developer Account** ($99/year) — https://developer.apple.com/programs/
2. **Xcode Command Line Tools** — `xcode-select --install`
3. **A Mac** (you already have this)

## Step 1: Create Signing Certificate

After enrolling in the Apple Developer Program:

1. Open **Keychain Access** on your Mac
2. Go to https://developer.apple.com/account/resources/certificates/list
3. Click **+** to create a new certificate
4. Choose **Developer ID Application** (this is for apps distributed OUTSIDE the App Store)
5. Follow the prompts (create a CSR from Keychain Access, upload it)
6. Download and double-click the certificate to install it in your Keychain

Verify it installed:
```bash
security find-identity -v -p codesigning
```

You should see something like:
```
1) ABCDEF1234... "Developer ID Application: Eric Bintner (TEAMID)"
```

Copy the full name in quotes — you'll need it for signing.

## Step 2: Create App-Specific Password

Notarization requires an app-specific password (NOT your Apple ID password):

1. Go to https://appleid.apple.com/account/manage
2. Under **Sign-In and Security**, click **App-Specific Passwords**
3. Click **+**, name it "PowerMate Notarization"
4. Copy the generated password (format: `xxxx-xxxx-xxxx-xxxx`)

Store it in your Keychain for easy reuse:
```bash
xcrun notarytool store-credentials "PowerMate-Notarize" \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

Find your Team ID at https://developer.apple.com/account — it's the 10-character string next to your name.

## Step 3: Build & Sign

```bash
# 1. Build release
./scripts/build-dmg.sh --release

# 2. Sign the .app bundle (replace with YOUR certificate name)
codesign --deep --force --options runtime \
  --sign "Developer ID Application: Eric Bintner (TEAMID)" \
  build/PowerMateReborn.app

# 3. Verify signature
codesign --verify --deep --strict build/PowerMateReborn.app
echo $?  # should print 0

# 4. Rebuild the DMG with the signed app
# (The build script already created one, but we need to remake it with the signed app)
rm -f build/PowerMateReborn_v1.0.0.dmg
hdiutil create -volname "PowerMateReborn" \
  -srcfolder build/PowerMateReborn.app \
  -ov -format UDZO \
  build/PowerMateReborn_v1.0.0.dmg
```

## Step 4: Notarize

```bash
# Submit for notarization (uses stored credentials from Step 2)
xcrun notarytool submit build/PowerMateReborn_v1.0.0.dmg \
  --keychain-profile "PowerMate-Notarize" \
  --wait

# If successful, staple the notarization ticket to the DMG
xcrun stapler staple build/PowerMateReborn_v1.0.0.dmg
```

The `--wait` flag blocks until Apple's servers finish checking (usually 2-5 minutes).

If it fails, check the log:
```bash
xcrun notarytool log <submission-id> --keychain-profile "PowerMate-Notarize"
```

## Step 5: Upload to GitHub

1. Go to https://github.com/EricBintner/PowerMateReborn/releases
2. Click **Draft a new release**
3. Tag: `v1.0.0`, Title: `PowerMateReborn 1.0.0`
4. Upload `build/PowerMateReborn_v1.0.0.dmg`
5. Publish

## Step 6: Update Sparkle Appcast

```bash
# Sign the DMG for Sparkle auto-updates
.build/artifacts/sparkle/Sparkle/bin/sign_update build/PowerMateReborn_v1.0.0.dmg
```

This prints an `edSignature` and `length`. Update `docs/appcast.xml`:
- Replace `REPLACE_WITH_EDDSA_SIGNATURE` with the edSignature
- Replace `REPLACE_WITH_FILE_SIZE_BYTES` with the length
- Replace `REPLACE_WITH_RFC2822_DATE` with: `date -R`

Then commit and push to update the appcast on GitHub Pages.

## Quick Reference: Full Release Workflow

```bash
# Build
./scripts/build-dmg.sh --release

# Sign
codesign --deep --force --options runtime \
  --sign "Developer ID Application: Eric Bintner (TEAMID)" \
  build/PowerMateReborn.app

# Remake DMG with signed app
hdiutil create -volname "PowerMateReborn" \
  -srcfolder build/PowerMateReborn.app \
  -ov -format UDZO \
  build/PowerMateReborn_v1.0.0.dmg

# Notarize
xcrun notarytool submit build/PowerMateReborn_v1.0.0.dmg \
  --keychain-profile "PowerMate-Notarize" --wait
xcrun stapler staple build/PowerMateReborn_v1.0.0.dmg

# Sparkle signing
.build/artifacts/sparkle/Sparkle/bin/sign_update build/PowerMateReborn_v1.0.0.dmg

# Upload to GitHub Releases, update docs/appcast.xml, push
```

## Common Issues

- **"Developer ID Application certificate not found"** — Make sure you downloaded the cert from developer.apple.com and installed it in Keychain
- **"The signature is invalid"** — Try `codesign --deep --force` to re-sign all nested frameworks
- **Notarization fails with "hardened runtime"** — The `--options runtime` flag enables hardened runtime, which is required
- **"The executable requests the com.apple.security.cs.disable-library-validation entitlement"** — Add this to your `.entitlements` file if Sparkle needs it
