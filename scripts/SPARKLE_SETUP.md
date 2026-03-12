# Sparkle Auto-Update Setup Guide

## Overview

PowerMateReborn uses [Sparkle 2](https://sparkle-project.org/) for auto-updates. This guide covers setting up the appcast feed on GitHub Pages.

## Step 1: Generate EdDSA Key Pair

Sparkle 2 uses EdDSA (Ed25519) signatures. Generate a key pair:

```bash
# From the project directory — Sparkle's generate_keys tool
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

This prints a **public key** and stores the **private key** in your Keychain.

- Copy the public key into `Info.plist` under `SUPublicEDKey`
- The private key stays in Keychain (used for signing updates)

## Step 2: Set Up GitHub Pages

1. Go to your repo: `https://github.com/EricBintner/PowerMateReborn`
2. Settings > Pages
3. Source: **Deploy from a branch**
4. Branch: `main` (or `gh-pages`), folder: `/docs`
5. Create the `docs/` folder in your repo root:

```bash
mkdir -p docs
cp scripts/appcast-template.xml docs/appcast.xml
git add docs/
git commit -m "Add appcast for Sparkle updates"
git push
```

Your appcast will be available at:
`https://ericbintner.github.io/PowerMateReborn/appcast.xml`

## Step 3: Sign a Release

After building a `.dmg`:

```bash
# Sign the DMG with your EdDSA private key
.build/artifacts/sparkle/Sparkle/bin/sign_update build/PowerMateReborn_v1.1.0.dmg
```

This outputs an `edSignature` and `length`. Paste both into the `<enclosure>` tag in `docs/appcast.xml`.

## Step 4: Publish a Release

1. Build the DMG: `./scripts/build-dmg.sh --release`
2. Sign it (Step 3 above)
3. Create a GitHub Release with tag `v1.1.0`
4. Upload the `.dmg` to the release
5. Update `docs/appcast.xml` with:
   - `sparkle:edSignature` from the sign_update output
   - `length` (file size in bytes): `wc -c < build/PowerMateReborn_v1.1.0.dmg`
   - `pubDate` in RFC 2822 format: `date -R`
6. Commit and push the updated appcast
7. Users with the app installed will see the update notification

## Info.plist Keys

These must be set in the app's `Info.plist` (the build script generates these):

| Key | Value |
|-----|-------|
| `SUFeedURL` | `https://ericbintner.github.io/PowerMateReborn/appcast.xml` |
| `SUPublicEDKey` | Your EdDSA public key from Step 1 |

## Troubleshooting

- **"No updates available"** — Check that `SUFeedURL` matches your GitHub Pages URL
- **Signature mismatch** — Regenerate keys and re-sign the DMG
- **Sparkle not initializing** — Only works inside a `.app` bundle (not `swift run`)
