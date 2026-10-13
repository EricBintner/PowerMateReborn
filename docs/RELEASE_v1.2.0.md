# Release v1.2.0 — Runbook

**Status: PREPARED — not yet built or published.** Work through top to bottom; do not skip the verify steps. Every "STOP" in here exists because a past release shipped wrong (see [RELEASE_PITFALLS.md](RELEASE_PITFALLS.md)).

Target: `v1.2.0` — "Settings Window & Stability Release" (29 commits since v1.1.0)

---

## Phase 0 — One-time setup (skip if already done)

Notarization credentials (from [scripts/CODE_SIGNING.md](../scripts/CODE_SIGNING.md) Step 2):

```bash
xcrun notarytool store-credentials "PowerMate-Notarize" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

Verify the Developer ID signing cert exists (build-dmg.sh hardcodes the identity, so it fails loudly if missing):

```bash
security find-identity -v -p codesigning
# must list: "Developer ID Application: Eric Bintner (FU96NT58N5)"
```

## Phase 1 — Pre-flight

1. Quit any running PowerMateReborn (menu → Quit) — two instances fight over the knob.

2. Confirm a clean tree and push everything first, so the tag points at a pushed commit:

```bash
cd /Volumes/Thunderbolt/AI/PowerMateReborn/PowerMateReborn
git status --short          # only expected: .DS_Store / .bug-hunt noise
git push origin main        # ~21 commits are unpushed right now
```

3. Confirm the notary profile resolves:

```bash
xcrun notarytool store-credentials --check --keychain-profile "PowerMate-Notarize"
```

## Phase 2 — Build, sign, notarize (one command)

```bash
./scripts/build-dmg.sh --release
```

This now does everything: release build → bundle with embedded Sparkle → Info.plist v1.2.0 → Developer ID sign (fail-loud) → DMG → notarize + staple (fail-loud) → final Sparkle EdDSA signature printed.

Copy the final output lines for the next phase:
- `sparkle:edSignature="..."` and `length="..."` (from the **post-notarization** sign_update output)
- the build number — echo it after the build:

```bash
plutil -extract CFBundleVersion raw build/PowerMateReborn.app/Contents/Info.plist
```

If notarization fails: `xcrun notarytool log <submission-id> --keychain-profile "PowerMate-Notarize"` — do not publish.

## Phase 3 — Verify the artifact (the v1.1.0 lesson)

```bash
plutil -p build/PowerMateReborn.app/Contents/Info.plist | grep -E "CFBundleShortVersionString|SUPublicEDKey"
codesign --verify --deep --strict build/PowerMateReborn.app
otool -L build/PowerMateReborn.app/Contents/MacOS/PowerMateReborn | grep Sparkle
spctl -a -vv build/PowerMateReborn.app
xcrun stapler validate build/PowerMateReborn_v1.2.0.dmg
```

**STOP if any of these fail:**
- `CFBundleShortVersionString` ≠ `1.2.0` → stale bundle, do not ship.
- `SUPublicEDKey` ≠ `SiMfU+5TNl47TWuyIcSiH2bIxGIukFt0UEz9XMl5NiE=` → key drift, do not ship.
- codesign/otool/spctl/stapler failures → do not ship.

Then **launch it and smoke-test** before publishing:

```bash
open build/PowerMateReborn.app
```

- Knob controls volume; menu readouts update live.
- Settings… opens the window; all six sections reflect reality; a toggle persists across relaunch.
- Custom section: profile editor loads.
- Check for Updates… is enabled and finds "up to date" against the live appcast (this also proves the SUFeedURL + EdDSA key in this build are correct end-to-end).

## Phase 4 — Publish

1. **Tag first, then release, in one sitting:**

```bash
date -R                                     # note the timestamp
git tag -a v1.2.0 -m "Settings window, launch-crash fix on built-in displays, notarized builds, stability fixes"
git push origin v1.2.0
```

2. **Create the GitHub release** (web UI or `gh`), title `PowerMateReborn 1.2.0`, tag `v1.2.0`, and **upload `build/PowerMateReborn_v1.2.0.dmg` in the same sitting** — never re-use a DMG built in a previous session (PITFALLS Part 1 rule 3). Paste the release notes below.

3. **Activate the appcast item immediately** — uncomment the v1.2.0 `<item>` block in [docs/appcast.xml](appcast.xml) (it sits directly above the v1.1.0 item, newest-first) and fill in the four `TO_BE_FILLED_AT_RELEASE` placeholders with the values from Phase 2. One command does both (tested against a copy of the appcast; it parses the result and fails if the item isn't first):

```bash
python3 - "$(date -R)" "BUILD_FROM_PHASE_2" "LENGTH_FROM_PHASE_2" "EDDSA_FROM_PHASE_2" <<'EOF'
import sys
pubdate, build, length, edsig = sys.argv[1:5]
path = 'docs/appcast.xml'
src = open(path).read()

# The v1.2.0 section is ONE comment: from its opening marker to the first -->
start = src.index('    <!-- v1.2.0 item goes HERE')
end = src.index('-->', start) + 3
block = src[start:end]

# The real item inside the comment runs from the '<item>' line to '</item>'
item_off = block.index('<item>')
line_start = block.rindex('\n', 0, item_off) + 1
item_end = block.index('</item>') + len('</item>')
item_block = block[line_start:item_end]

# Replace the whole comment with the uncommented item
src = src[:start] + item_block + src[end:]

# Fill placeholders, scoped to the v1.2.0 item (before the v1.1.0 title)
cut = src.index('<title>Version 1.1.0')
head, tail = src[:cut], src[cut:]
head = head.replace('TO_BE_FILLED_AT_RELEASE</pubDate>', pubdate + '</pubDate>')
head = head.replace('TO_BE_FILLED_AT_RELEASE</sparkle:version>', build + '</sparkle:version>')
head = head.replace('length="TO_BE_FILLED_AT_RELEASE"', 'length="%s"' % length)
head = head.replace('sparkle:edSignature="TO_BE_FILLED_AT_RELEASE"', 'sparkle:edSignature="%s"' % edsig)
src = head + tail

assert 'TO_BE_FILLED_AT_RELEASE' not in src
import xml.dom.minidom
doc = xml.dom.minidom.parseString(src)  # raises if malformed
titles = [i.getElementsByTagName('title')[0].firstChild.data for i in doc.getElementsByTagName('item')]
assert titles[0] == 'Version 1.2.0 (Settings Window & Stability Release)', titles
assert len(titles) == 3, titles
open(path, 'w').write(src)
print('activated:', titles)
EOF
```

(Read the script before running it — trust, but verify.) Then verify and publish:

```bash
xmllint --noout docs/appcast.xml
git add docs/appcast.xml
git commit -m "Publish appcast for v1.2.0"
git push origin main
```

**Ordering matters:** the DMG must be live at the enclosure URL *before* the appcast advertises it, or auto-update 404s for every v1.1.0 user mid-rollout. GitHub Releases assets are live the moment the release is published, so: release → appcast commit → push.

4. **Confirm the live appcast** (after Pages rebuilds, ~1 min):

```bash
curl -s https://ericbintner.github.io/PowerMateReborn/appcast.xml | grep -A2 "1.2.0"
```

**Final rule:** any re-upload of the DMG ⇒ re-run sign_update ⇒ update `length` + `edSignature` in the appcast ⇒ re-push. A signature computed over one file only verifies that exact file.

---

## Release notes (paste into the GitHub release)

```markdown
## PowerMateReborn 1.2.0 — Settings Window & Stability Release

This release fixes a **launch crash on Macs with a built-in display** (MacBooks, iMacs) present since 1.0, and completely redesigns how settings work.

### Highlights

- **New Settings window** — all the advanced configuration that used to bury the status menu (output device, enabled modes, tap actions, sensitivity, LED, MIDI, displays, launch-at-login) now lives in a proper window, organized into **General / Audio / Knob / Displays / MIDI / Custom** sections. The Custom Mode profile editor is part of it too — no more separate window. The status menu keeps just the everyday essentials.
- **Fixed: launch crash on built-in displays** — a mis-declared private API crashed the app at launch on any Mac with a built-in screen. External-display-only Macs (Mac Studio, mini) were unaffected, which is why it slipped through.
- **Notarized builds** — the DMG is now notarized with Apple, so Gatekeeper lets it open without the "can't be verified" wall.
- **In-app issue reporting** — "Report Issue…" pre-fills a GitHub issue with your system info and recent logs attached.
- **Bluetooth, done properly** — time-boxed scanning with exponential backoff, no more Bluetooth permission nag, and the BLE connect dead-ends are gone.

### Also in this release

- Settings save immediately on change (previously lost on force-quit)
- Adjustable long-press / double-tap timing (Settings → Knob → Advanced)
- Fixed: CoreAudio listener leaks on every device switch
- Fixed: OSD showing 100% while the display looked ~60% (stuck brightness)
- Fixed: gesture glitches — long-press canceling on rotation, double-tap misdetection
- Fixed: identical external monitors no longer confuse per-display brightness prefs
- Gamma restore via ColorSync (survives unusual display configs)
- Custom Mode: Accessibility permission now surfaced when missing; event-monitor leak and profile-index crash fixed
- Sparkle updater no longer starts with a broken/placeholder update config

**Requirements:** macOS 13+. If you use Custom Mode scroll/keyboard actions, grant Accessibility permission (System Settings → Privacy & Security → Accessibility).
```