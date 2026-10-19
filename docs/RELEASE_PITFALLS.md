# PowerMateReborn — Release & Engineering Pitfalls (Post-Mortem)

Compiled 2026-10-12 from the bug hunt on this machine (Mac Studio M1 Max, macOS 26.5.1) and from issue #1 (timfurnish + comments by cortig and D-hatu), plus the denebmac-crypto fork's findings. Every item below is something we actually hit or verified — not theory.

---

## Part 1 — The v1.1.0 Release That Shipped v1.0.0

### What happened (verified via git)

- `git show v1.0.0:scripts/build-dmg.sh` → `VERSION="${POWERMATE_VERSION:-1.0.0}"`, `SUPublicEDKey` = `REPLACE_WITH_YOUR_EDDSA_PUBLIC_KEY`, and **no Sparkle-framework embedding step at all**.
- `git show v1.1.0:scripts/build-dmg.sh` → `VERSION=1.1.0`, real EdDSA key, embedding present (`commit 02e0000`).
- timfurnish's download (labeled v1.1.0 from the DMG link) identified itself as **v1.0.0**, had the **placeholder EdDSA key**, and **crashed with "Library not loaded: Sparkle"** — three fingerprints of v1.0.0-era code.
- Conclusion: **the DMG attached to the v1.1.0 release was built from stale v1.0.0-era sources, not from the v1.1.0 tag.**

### How to never do this again (process checklist)

1. **Build from a clean checkout of the tag** — never from the working tree:
   ```bash
   git fetch --tags
   git checkout v1.2.0
   rm -rf .build && swift build -c release
   ```
2. **Verify before upload.** After packaging, before touching GitHub Releases, run:
   ```bash
   plutil -p "PowerMateReborn.app/Contents/Info.plist" | grep -E "CFBundleShortVersionString|SUPublicEDKey"
   codesign --verify --deep --strict PowerMateReborn.app
   otool -L PowerMateReborn.app/Contents/MacOS/PowerMateReborn | grep Sparkle
   spctl -a -vv PowerMateReborn.app   # should say "accepted, Developer ID"
   ```
   If `CFBundleShortVersionString` ≠ the release name, the DMG is stale — stop.
3. **Attach the DMG in the same step that builds it.** The failure mode here was a build artifact surviving from a previous release-cycle session. Treat any DMG not built in this run as stale.
4. **EdDSA key typo class of bug:** the v1.1.0 bundle shipped `…47Tw…`; the fix (`483020d`, "Tw -> TW") landed the day *after* release. The key in the shipped bundle's Info.plist and the `sparkle:edSignature` in `docs/appcast.xml` are **two different keys for two different things** (bundle trust vs. DMG download trust). When rotating either, grep for **case-sensitive** typos, and verify the shipped DMG can actually see/verify an update before publishing.
5. **The DMG in the appcast must match the DMG in the release.** Commit `5d0314b` updated the v1.0.0 item's `length` and `edSignature` "for notarized dmg" — but a signature computed over one file only verifies that exact file. If the release asset was ever re-uploaded, the appcast is silently stale for everyone. Rule: any re-upload ⇒ regenerate `sparkle:edSignature` + `length` ⇒ update appcast ⇒ publish together.

### The one-line code fix that unblocks all MacBook users

`Sources/BrightnessController.swift:24` declares the private API as `(UInt32) -> Float`. The real signature is `(UInt32, UnsafeMutablePointer<Float>) -> Bool`. On Macs with a built-in display, the wrong call writes through a garbage out-pointer → `EXC_BAD_ACCESS` during `BrightnessController.init()` at every launch. On external-display-only Macs (Mac Studio/mini) it survives — which is why it went unnoticed here. (The denebmac fork's main branch still has this bug too.)

---

## Part 2 — Packaging pitfalls (Sparkle, signing, notarization)

Each of these was either hit by a user or verified on this machine:

1. **SwiftPM framework path drift.** `scripts/build-dmg.sh:66` hardcodes `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`. That path only exists after a successful `swift build` populates it. On a clean checkout/CI, the script dies at `cp -R` under `set -e`. The fork's fix: `find .build -type d -name Sparkle.framework` with a hard error if missing — copy that pattern instead of hardcoding.
2. **Load-command rewiring.** After embedding Sparkle, the binary's `@rpath` load must resolve inside the bundle. We add `@executable_path/../Frameworks` rpath in build-dmg.sh:67; the fork additionally uses `install_name_tool -change` to rewrite the dep to the exact `Versions/<v>/Sparkle` path and **fails the build loudly if it can't parse the version** (their commits 79d714f, 5ae97d2, ec13068). Silent skip = the exact timfurnish crash.
3. **Notarization is absent.** `build-dmg.sh` signs with Developer ID but never calls `notarytool`/`stapler`. On macOS 15+ Gatekeeper blocks un-notarized DMG-installed apps ("cannot verify developer"). Add:
   ```bash
   xcrun notarytool submit PowerMateReborn_v1.2.0.dmg --keychain-profile notary-profile --wait
   xcrun stapler staple PowerMateReborn_v1.2.0.dmg
   ```
4. **Missing `NSAppleEventsUsageDescription`** in the generated Info.plist. On macOS 15+ TCC requires this key for NSAppleScript → System Events (the AppleScript volume fallback and `sleepDisplay()`). Without it, scripts fail with -1743 and volume control silently degrades to software. (The fork removed AppleScript volume entirely in their rewrite; if we keep it, add the key AND an Accessibility/Automation prompt at first use.)
5. **Sparkle should not start with incomplete config.** timfurnish's item 3: `SPUStandardUpdaterController(startingUpdater: true, ...)` runs even when `SUFeedURL`/`SUPublicEDKey` are placeholder/absent → blocking "Unable to Check For Updates" modal at launch. The fork's fix (5c68bb4): only start the updater when `SUFeedURL` exists and is non-blank. Adopt, and extend it to also check `SUPublicEDKey` is present, non-placeholder, and looks like base64 (44 chars ending in `=`).
6. **Ad-hoc signed frameworks inside a Developer-ID-signed app.** build-dmg.sh signs Sparkle's nested XPC services with the Developer ID identity, but on machines without that identity in the keychain the `|| true` guards hide it; the app then ships with mismatched nested signatures → spurious "damaged app" reports. Fail the build if signing fails; never `|| true` a signature.
7. **Info.plist is regenerated by the build script, not a source-controlled file.** Keys drift between builds (see the SUFeedURL/SUPublicEDKey history). Keep a real `Resources/Info.plist` in git as the source of truth; generate only the version/build fields at package time.
8. **Appcast channel `<link>` still points at `Docs/appcast.xml`** (capital D) — renamed to `docs/` in f51e061. Harmless to Sparkle (uses SUFeedURL) but breaks any human following the link; grep the appcast after directory renames.
9. **Version-reported-in-About mismatch** (timfurnish: "v1.1.0 download identified as v1.0.0"): About reads `CFBundleShortVersionString` from the bundle. This is symptom, not cause — covered by the Part 1 checklist.

---

## Part 3 — Hardware & sleep pitfalls (verified empirically)

1. **Phantom HID activity keeps the display awake — even with the app dead.** WindowServer holds a permanently-fresh `UserIsActive` tickle attributed to `AppleUserHIDEventService product:Griffin PowerMate eventType:3`. **Root cause (found 2026-10-18, not the hub):** the knob's descriptor declares its LED echo bytes as a Consumer Control usage, so a knob report sent while the LED is lit registers as a *held media key* that macOS auto-repeats at the key-repeat rate (83 ms here) — forever, even after the app quits. Fixed in the app by seizing the device (`kIOHIDOptionsTypeSeizeDevice`) so macOS stops interpreting its reports, plus declaring user activity on real knob input so the knob still wakes the display. Diagnose with a HIDIdleTime sampler: resets at exactly the key-repeat interval = stuck key. D-hatu's "preventing sleep" on Mac Studio is this.
2. **BLE scan never times out** (`PowerMateBLETransport.startScanning`) — runs forever whenever Bluetooth is `.poweredOn` and no BLE PowerMate exists, keeping bluetoothd busy holding `PreventUserIdleSystemSleep` (com.apple.BTStack). This one **is** app-caused. Add a scan timeout + exponential backoff.
3. **`CBCentralManagerOptionShowPowerAlertKey: true`** — a "Turn on Bluetooth?" system nag for USB-only users on fresh installs. Default to `false`; make Bluetooth opt-in.
4. **The DisplayServices crash only reproduces on Macs with a built-in display** — a headless-capable test matrix is misleading. Test releases on at least: MacBook (built-in display), Mac mini/Studio (external only), each on the two latest macOS versions.
4b. **`restoreGamma()` writes the captured table back directly** — the fork found (bbabb86) that on modern macOS "especially Tahoe", `CGSetDisplayTransferByTable` behaves inconsistently, preferring `CGDisplayRestoreColorSyncSettings()` to restore profile-defined tables instead. Adopt.
5. **DDC/CI silently fails on HDMI monitors via IOAVService** (observed on LG HDR 4K here: "no IOAVService found") — the Gamma fallback covers it, but log/README it so users don't expect hardware brightness.

---

## Part 4 — What the fork (denebmac-crypto/PowerMateReborn) found that we hadn't

They rewrote the profile system (multi-device, per-device mappings) and canvas rotation, but the directly relevant engineering finds:

| Their commit | What it fixed | Do we adopt? |
|---|---|---|
| `5c68bb4` defer Sparkle startup until appcast configured | timfurnish's blocking-updater-modal issue | **Yes** — plus our stronger key validation |
| `79d714f` + `5ae97d2` + `ec13068` Sparkle packaging | Deterministic framework discovery (find, not hardcoded path), fail-loud version parsing, post-sign `codesign --verify`, `otool -L` dump | **Yes** — replace build-dmg.sh lines 63–67 |
| `18a47e0` weak-link Sparkle for CLI dev runs | Lets `swift run` work without the framework | Consider — nice dev ergonomics |
| `09f6921` request synthetic input permission at startup | Our HEAD posts CGEvents (scroll/keyboard) with **no** `AXIsProcessTrusted` check — Custom Mode silently does nothing on fresh macOS until the user grants Accessibility | **Yes** — check + prompt at first use |
| `bbabb86` restore gamma via ColorSync | Tahoe `CGSetDisplayTransferByTable` inconsistency (see Part 3 §4b) | **Yes** |
| `85e7255` CI build workflow | Push-builds the app on macOS runners | Yes, plus artifact upload + our verify steps |
| `f77af48` package app + DMG in CI | Packaging in a clean environment every time | **Yes** — this alone prevents Part 1's stale-DMG class |

What they did **not** fix (their main branch still has it): the DisplayServices signature bug, the CoreAudio listener-removal bug, the gesture long-press/tapCount bugs, the BLE scan timeout, the USB LED race, the DDC use-after-free, and the phantom-HID sleep issue. So a PR from them would not close those gaps — ours needs them anyway.

---

## Part 5 — Full bug inventory reference

All findings, empirical evidence, agent reports verbatim, and fix priorities live in [`.bug-hunt/TESTING.md`](../.bug-hunt/TESTING.md) (untracked working notes). Summary of counts: 1 launch-crash (MacBooks only), 1 release-process failure, ~10 high/medium code bugs, ~8 low/leak issues, 2 hardware/OS interactions (phantom HID, BTStack), 3 packaging/signing gaps.

---

*Document generated during the 2026-10-12 bug hunt. Evidence: `pmset -g assertions` logs, passive HID sniffer run, wrong-vs-right signature test harness (`.bug-hunt/hid-sniffer.swift`), git archaeology of the release tags, and the issue #1 thread.*