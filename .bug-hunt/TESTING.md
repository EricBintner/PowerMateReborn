# PowerMateReborn — Bug Hunt Report (2026-10-12)

## Verified on this machine (Mac Studio M1 Max, macOS 26.5.1, PowerMate USB connected)

### Confirmed empirically

1. **DisplayServices launch crash on MacBooks** — `BrightnessController.swift:24-25` declares `DisplayServicesGetBrightness` as `(UInt32) -> Float`. The real private API is `(UInt32, UnsafeMutablePointer<Float>) -> Bool`. On a MacBook with a **built-in display**, the function dereferences the garbage second argument as an out-pointer → `EXC_BAD_ACCESS` in `BrightnessController.init()` at every launch (issue #1, timfurnish + cortig). On this Mac Studio (external LG display, `CGDisplayIsBuiltin==0`), the wrong call survives (returned 0.0 five times, no crash) — which is why it doesn't crash here.
   - The probe path is `AppDelegate` → `BrightnessController.init()` → `probeDisplays()` → `detectMethod()` → `dsGetBrightness(displayID)` — runs before `applicationDidFinishLaunching`.
   - Fix: change typealias to `(UInt32, UnsafeMutablePointer<Float>) -> Bool`, handle Bool return, use a single helper everywhere.

2. **The v1.1.0 release shipped a stale DMG built from v1.0.0-era code** (explains "v1.1.0 reports as 1.0.0" + placeholder key + missing Sparkle):
   - `git show v1.0.0:scripts/build-dmg.sh` → `VERSION=1.0.0`, `SUPublicEDKey=REPLACE_WITH_YOUR_EDDSA_PUBLIC_KEY`, **no** Sparkle embedding step.
   - `git show v1.1.0:scripts/build-dmg.sh` → `VERSION=1.1.0`, real EdDSA key, Sparkle embedding present.
   - timfurnish's download identified as v1.0.0 with the placeholder key — i.e. the DMG attached to the v1.1.0 release was built from the old script, not from the v1.1.0 tag. Release process bug (rebuild + re-upload the DMG from the tag).

3. **v1.1.0's EdDSA key had a typo** (`…47Tw…` vs `…47TW…`, fixed in 483020d the day after release) → Sparkle verification fails on update checks even for the fixed bundles. The appcast's `sparkle:edSignature` was regenerated for the new binary in 707c0a1 but v1.1.0 item in `docs/appcast.xml` now shows the key that matches the **current** binary, not what shipped in the v1.1.0 DMG.

4. **PowerMate knob phantom HID activity prevents display sleep on Mac Studio** (issue #1 comment, D-hatu "preventing sleep"). Experiments on this machine:
   - App running, 3-min idle monitor (nobody touching anything): WindowServer `UserIsActive` tickle assertion attributed to `AppleUserHIDEventService product:Griffin PowerMate eventType:3` was freshly re-tickled (age 00:00:00) in **all 6 samples**. The app's own log stayed at 34 lines — the app saw no rotation events.
   - **App killed** (pkill, confirmed dead), 2.5-min monitor: tickle still fresh in **all 10 samples** — the phantom activity does NOT come from the app.
   - Passive userspace sniffer (`.bug-hunt/hid-sniffer.swift`, IOHIDDeviceRegisterInputReportCallback): **zero raw input reports in 90s** — the phantom scroll tickles originate below the app-visible report level (kernel HID event system / hub remote-wakeup noise; the knob sits behind a GenesysLogic 4-port USB hub per `ioreg`).
   - Conclusion: D-hatu's "preventing sleep" is a **hardware/USB-stack interaction, not app-caused** — it persists with the app dead. User-side mitigations: plug the PowerMate directly into the Mac (no hub), try another port/cable/hub, or reduce display-sleep sensitivity. Worth documenting in README/issues as "known: certain USB hubs + PowerMate keep the display awake".
   - Separately confirmed live: the app's BLE transport scans forever (`BLE: Scanning...` at 09:20:16, no stop) whenever Bluetooth is on and no BLE PowerMate exists — keeps bluetoothd holding `PreventUserIdleSystemSleep` (com.apple.BTStack, visible in every early sample). On Macs using the Bluetooth knob this compounds the sleep problem and IS app-caused (fix: scan timeout in `PowerMateBLETransport.startScanning`). Also `CBCentralManagerOptionShowPowerAlertKey: true` (PowerMateBLETransport.swift:48) pops a "Turn on Bluetooth?" nag for USB-only users on fresh installs.

5. **DDC/CI broken on this very setup**: the app's DDC probe reports `DDC: display 1 'LG Display' — no IOAVService found` and falls back to Gamma. The display (LG HDR 4K via HDMI) likely doesn't support DDC/CI brightness via IOAVService on Apple Silicon — brightness control still works via Gamma fallback.

6. **Build environment fragility**: on this machine (Swift 6.3, macOS 26), `swift build` puts Sparkle at `.build/arm64-apple-macosx/release/Sparkle.framework` AND `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/...` — the build-dmg.sh path works here, but the script relies on `.build/artifacts` existing (SwiftPM's artifact-root). A clean checkout without `swift build` first (CI) would die at line 66. Not a user-facing bug.

### Confirmed by code reading (high confidence, not yet run)

7. **CoreAudio volume listener removal never works** — `VolumeController.swift` `removeVolumeListeners()` passes a fresh `{ _, _ in }` block to `AudioObjectRemovePropertyListenerBlock`, which matches by block identity → nothing is ever removed. Listeners accumulate per device switch; `onExternalVolumeChange` keeps firing for dead devices.

8. **Gesture state machine**: `PowerMateManager.swift:115-120` — `rotatedWhilePressed` set on rotation but `longPressTimer` never canceled → press-and-rotate past 0.5s fires long-press (mode switch) mid-rotation. Also `onButtonUp` early-return (line 169-173) doesn't reset `tapCount` → press-rotate-release then a single tap registers as double-tap (mute/sleep-display).

9. **Duplicate MIDI virtual source**: `CustomModeEngine.swift:119` creates a second `MIDIController()` → two identical "PowerMate Knob" sources in MIDI apps, both emitting CC events per rotation (confirmed in live log: two "MIDI: virtual source 'PowerMate Knob' created" lines).

10. **`updaterDidNotFindUpdate` delegate signature wrong** — `AppDelegate.swift:946` has an `error:` parameter that Sparkle's `SPUUpdaterDelegate` method doesn't take → dead method, never called, compiles as dead code (the correct one has no error param).

11. **Notarization absent** — `build-dmg.sh` signs with Developer ID but never calls `notarytool`/`stapler`. On macOS 15+ (Sequoia) Gatekeeper requires notarization even for ad-hoc/unsigned apps run by right-clicking — first launch of the DMG-installed app can be blocked with "cannot verify developer" on new Macs. CODE_SIGNING.md mentions notarization but the script doesn't perform it.

12. **`NSAppleEventsUsageDescription` missing from generated Info.plist** — on macOS 15+ TCC requires this key (or a per-app automation permission) for `NSAppleScript` → System Events (volume AppleScript fallback + `sleepDisplay()`). Without it the scripts fail with -1743 and volume control silently falls back to software.

13. **AppleScript volume fallback is synchronous on main** — `getVolume()` on the AppleScript path runs `NSAppleScript.executeAndReturnError` on the main thread per knob tick → beachballs when falling back to AppleScript on Macs without CoreAudio hardware volume (many new Macs with virtual audio devices, e.g. virtual-display setups).

### Code-reading findings from review fleet (unverified by me — triage recommended)

14. **DDCController use-after-free race** (HIGH, DDCController.swift:204-214 vs 87-92): `flushWrite` captures `display.service` into a `ddcQueue.async` block while `probeDisplays()` on main can `IOObjectRelease` those services. Crash on wake/reconfig concurrent with knob activity.

15. **USB LED-test race** (HIGH, PowerMateUSBTransport.swift:87-100 vs 129-131): startup LED flash reads `device`/`ledBrightness` on a global queue while main can nil the device (hot-unplug) → sporadic EXC_BAD_ACCESS on hot-plug, classic "works on old Mac, crashes on new Mac".

16. **DDC `externalDisplayIndex` silent 0-fallback** (MED, DDCController.swift:247-259): two external displays can both map to index 0 → same io_service stored under two keys → double release + wrong display controlled.

17. **BLE dead-end on discovery failure** (HIGH, PowerMateBLETransport.swift:192-196): `transportDidConnect` only fires if a notifiable characteristic was found; if discovery errors, scan already stopped, no retry → device stays "disconnected" forever, icon never updates. Plus reconnect retries every 1-2s forever without backoff; `didDisconnectPeripheral` never nils `self.peripheral`.

18. **Event monitor leak in settings** (HIGH, CustomModeSettingsView.swift:397): `startShortcutRecording()` adds a global keyDown monitor per click, never removed → monitors accumulate, each retaining the view and rewriting `config.keyboardShortcut` on every later keydown, even after the sheet closes.

19. **Retain/double-registration issues** (MED): `CustomModeEngine.startAppObserver()` KVO + notification observer never removed; `VolumeController` wake-observer token discarded; `BrightnessController` CGDisplay callback registered with `passUnretained(self)`, never removed, no deinit balance.

20. **Settings lost on SIGTERM/Ctrl-C** (MED-HIGH, main.swift + AppDelegate.swift:1197): `saveSettings()` only runs in `applicationWillTerminate`; the signal path calls `exit()` directly, skipping it → knob-config changes silently lost on logout/shutdown.

21. **`signalHandler` not async-signal-safe** (CRITICAL for theory, MED impact, main.swift:5-15): calls `restoreGamma()` + `NSLog` + `exit()` inside the handler. UB; can deadlock during logout (NSLog/malloc lock re-entry) → app hangs on logout, gamma not restored.

22. **OSDOverlay headless crash** (LOW, OSDOverlay.swift:87): `NSScreen.screens.first!` force-unwrap → crash on headless Mac Studio (no display attached) or SSH sessions.

23. **OSDOverlay `NSScreen.main!` in overlayWindow** (LOW, BrightnessController.swift:485): force-unwrap `NSScreen.main!` fallback — same headless risk in night-mode/overlay path.

22b. **MIDIPacketListAdd declared buffer 1024 vs actual ~272** (LOW, MIDIController.swift:119) — latent stack overrun if a message bigger than the struct's data area is ever built.

24. **`appcast.xml` channel `<link>` still points to `Docs/appcast.xml`** (capital D) — renamed to `docs` in f51e061. Sparkle uses SUFeedURL so this doesn't affect update checks, but the channel link is dead.

25. **Brightness prefs written per knob tick** (MED, BrightnessController.swift:266/379): `saveDisplayPreference` → `UserDefaults.set` on every rotation event → plist I/O per tick.

26. **usleep on main during DisplayServices set** (MED, BrightnessController.swift:227): 10ms stall per brightness change on the main thread.

### Debunked (checked, not bugs)

- Gamma-baseline corruption theory: safe in normal paths — `probeDisplays` reuses existing DisplayState and `applyGamma` always scales from `originalGamma`.
- Sync-mode double-apply of brightness delta: math is correct (delta computed once).
- Sparkle `.app` gating: `if Bundle.main.bundleURL.pathExtension == "app"` — fine for `swift run`.
- SwiftPM Sparkle artifacts path exists here; not a bug on this machine (watch it on CI/clean checkouts).
- No IOPMAssertions anywhere; no repeating timers; HID manager uses `kIOHIDOptionsTypeNone` (passive) — the app itself does not hold sleep assertions.
- BTStack sleep assertion persisted (briefly) even with the app dead on this machine — on this Mac the kernel/bluetoothd cycles it, and phantom HID tickles are the dominant display-sleep blocker. For a **Bluetooth** PowerMate setup the scan loop is app-caused and the fix belongs in the app; for D-hatu's USB setup the evidence points to hardware/hub, not the app.

## What a brand-new Mac would hit (theory, extrapolated)

**New MacBook Pro/Air (built-in display, macOS 15/26)**: instant `EXC_BAD_ACCESS` at launch via the DisplayServices signature bug — the app never appears (timfurnish + cortig).

**New Mac Studio/mini (external displays)**: app runs; phantom knob reports keep the display awake (D-hatu); DDC may fail on HDMI monitors without IOAVService (Gamma fallback OK); duplicate MIDI sources; gesture bugs degrade UX; Settings lost on logout; on macOS 15+ the un-notarized DMG may be blocked at first launch by Gatekeeper; missing NSAppleEventsUsageDescription kills the AppleScript volume fallback on fresh systems.

**Any Mac with a Bluetooth PowerMate**: scan loop never times out; radio stays busy; sleep issues plus the connect dead-end bug.

### Peer-audit additions (2026-10-12, from the capability-sniffing session) — fixed in fac7e1b

27. **Sticky capability cache** — probeDisplays() never re-ran detectMethod for attached displays; a display whose method degraded while attached (DDC dies after sleep, user disables DDC) silently no-oped forever. Fixed: DDC health re-check on every probe + `probeDisplays(forceRedetect:)` preserving gamma baselines.
28. **DDC settings order** — states probed at init with DDC defaulted on; `loadSettings` later disabled DDC without re-probing → DDC-cached displays writing into a disabled controller. Fixed: saved-setting change forces re-probe; toggle always re-probes.
29. **Per-display prefs never restored** — `as? [String: Float]` on a UserDefaults dictionary always fails (values are NSNumber). Fixed: NSNumber.floatValue conversion; verified live (seeded 0.42 → "restoring saved level 42%").
30. **Duplicate DDC probe on wake** — onSystemWake probed both directly and via onDisplayReconfigured. Fixed.
31. **OPEN: serial-key collision** — displaySerialKey is vendor-model-serial, and CGDisplaySerialNumber returns 0 for many external monitors → identical monitors collide in displayPreferences (both load/save the same entry, last-writer-wins). Needs a keying decision (locationID or EDID UUID); not yet fixed.

## Recommendations (priority order)

1. Fix DisplayServices signature (one-file fix, unblocks all MacBook users).
2. Rebuild + re-upload the v1.1.0 DMG from the v1.1.0 tag; add a release checklist (build from tag, verify Info.plist version + EdDSA key before upload).
3. Add notarization + NSAppleEventsUsageDescription to build-dmg.sh.
4. Fix CoreAudio listener removal (store the block, pass the same instance to remove).
5. Fix gesture timers (cancel longPressTimer on rotation; reset tapCount on suppressed paths).
6. Fix USB LED-race + DDC service-race (synchronize or snapshot device/service at capture time).
7. BLE: scan timeout + backoff + `didDisconnectPeripheral` nils peripheral; fix characteristic-discovery dead end.
8. Deduplicate the MIDIController (pass AppDelegate's instance into CustomModeEngine).
9. Make signalHandler async-signal-safe and save settings on `NSApplication.didTerminateNotification` too... actually use `NSApplication.willTerminateNotification` + a SIGTERM-safe flag-and-exit design.
10. Sleep: (a) add a BLE scan timeout/backoff in `PowerMateBLETransport` — app-caused for Bluetooth setups; (b) for the USB phantom-tickle (persists with app dead), document the hub workaround in the README and consider an FAQ entry pointing affected users to `pmset -g assertions` to self-diagnose.
11. Menu-bar discoverability (issue #1 item 4): add Dock-icon fallback toggle like timfurnish suggested.

## Test artifacts (in .bug-hunt/)

- `idle-monitor.sh` — 3-min power-assertion monitor (used above)
- `hid-sniffer.swift` — passive raw HID report counter (90s run, in progress)
- Reports from 6 review agents: appended below.

## Agent reports verbatim

### Agent A — AppDelegate / main.swift / MenuBarIcon (sonnet)
CRITICAL — main.swift:5-15. `signalHandler` is not async-signal-safe. It calls `AppDelegate.shared.brightnessController.restoreGamma()` (Swift/ObjC message dispatch, CoreGraphics table write) and `NSLog` (allocates, takes locks) from a SIGINT/SIGTERM context, then calls `exit()`, which itself runs atexit handlers and flushes stdio. This is undefined behavior. Failure: SIGTERM arrives (logout/shutdown) lost while the main thread holds an ObjC runtime/NSLog/malloc lock → the handler deadlocks re-entering that lock, the app hangs during logout and gamma is never restored. The `restoreGamma`+`NSLog` calls must be removed from the handler; at most set a volatile flag or use `_exit`.

HIGH — AppDelegate.swift:90-96 + 1197. Settings are persisted only in `saveSettings()`, only called from `applicationWillTerminate`. The signal path (`signalHandler` → `exit()`) never invokes `applicationWillTerminate`, so on Ctrl-C or SIGTERM every pending change is lost.

MEDIUM — AppDelegate.swift:39-45 + BrightnessController.init. All controllers eagerly constructed; any init crash aborts entire launch; no lazy isolation.

MEDIUM — AppDelegate.swift:946. `updaterDidNotFindUpdate(_:_:error:)` doesn't match Sparkle's `updaterDidNotFindUpdate(_:)` — dead method.

LOW — OSDOverlay.swift:87. `NSScreen.screens.first!` force-unwrap — headless crash.

### Agent B — BrightnessController / DDCController / OSDOverlay (sonnet)
HIGH — DDCController.swift:204-214 vs 87-92: use-after-free race on io_service_t between flushWrite's ddcQueue block and probeDisplays' IOObjectRelease.

HIGH — BrightnessController.swift:396-403: CGDisplayRegisterReconfigurationCallback with passUnretained(self), never removed, no deinit balance — dangling pointer path if controller is ever recreated.

MEDIUM — DDCController.swift:247-259: externalDisplayIndex silent 0-fallback → same service under two keys → double release.

MEDIUM — DDCController.swift:219-243: findIOAVService positional match leaks/over-releases on wrong match.

LOW — DDCController.swift:38/190-195: coalesceTimers entries never removed; pendingWrites/lastCommandTime not pruned for removed displays.

### Agent C — VolumeController / MIDIController / OSCController (haiku)
HIGH — VolumeController.swift:359 (with 601-623): removeVolumeListeners passes a fresh closure to AudioObjectRemovePropertyListenerBlock — matches by block identity → nothing removed. Listeners accumulate on every default-device change.

HIGH — VolumeController.swift:135, 784, 891: synchronous NSAppleScript on main thread; getVolume() every knob tick → choppy response.

MEDIUM — VolumeController.swift:935: getStringProperty leaks the +1 CFString from AudioObjectGetPropertyData.

MEDIUM — OSCController.swift:63-76: failed connections never removed/rebuilt — one transient failure permanently disables that host:port.

MEDIUM — VolumeController.swift:864-883: no Accessibility/Automation check; after 3 failures silently downgrades to .softwareVolume which reports success while doing nothing.

LOW — MIDIController.swift:119: MIDIPacketListAdd declared buffer 1024 vs ~272-byte actual — latent stack overrun.

LOW — VolumeController.swift:634: wake-observer token discarded; appleScriptTimer never invalidated in deinit.

### Agent D — USB/BLE/PowerMateManager/MenuBarIcon (haiku)
HIGH — PowerMateManager.swift:140 (+110-115): long-press timer never cancelled when rotation starts → mode switch mid-adjustment.

HIGH — PowerMateBLETransport.swift:192-196: transportDidConnect only emitted if notifiable characteristic found; discovery error leaves device dead forever.

MEDIUM — PowerMateManager.swift:164-167: rotatedWhilePressed early-return doesn't reset tapCount → false double-taps.

MEDIUM — PowerMateBLETransport.swift:117-124, 136-140: reconnect retry 1-2s forever, no backoff; didDisconnectPeripheral never nils peripheral.

MEDIUM — PowerMateManager.swift:181: Timer.scheduledTimer default run-loop mode → timers stall while menu open (event tracking mode).

MEDIUM — PowerMateUSBTransport.swift:88-100 vs 129-131: LED-test race on device/ledBrightness across threads.

LOW — PowerMateUSBTransport.swift:116-117: input report buffer leaked per device-match.

LOW — MenuBarIcon.swift:53-66: no caching; fresh NSImage on every updateStatusDisplay (every rotation tick).

### Agent E — sleep-prevention hunt (sonnet)
No IOPMAssertions, no repeating timers, no HID seize. Top suspect: endless BLE scan (PowerMateBLETransport.swift:74-76 startScanning with no timeout; only stops on discovery) keeping bluetoothd busy on Macs with Bluetooth on. Secondary: shielding-level overlay window while dimmed. On this Mac Studio the empirical cause is instead phantom knob scroll reports (WindowServer UserIsActive tickle), which the sniffer test will confirm.

### Agent F — CustomModeEngine + cross-file threading sweep (sonnet)
No Process/NSTask/osascript shell-outs in Custom Mode (answers Q1: no per-tick process spawn). AppleScript strings interpolate only numbers (Q5: no injection).

HIGH — CustomModeSettingsView.swift:397: global keyDown monitor added per Record click, never removed — leak + stale monitors rewriting config after sheet closes.

HIGH — PowerMateUSBTransport.swift:87-100: LED race (same as Agent D).

HIGH — DDCController.swift:198-215 vs 83-90: DDC service race (same as Agent B).

MEDIUM — BrightnessController.swift:266/379: UserDefaults write per knob tick; line 227 usleep(10_000) stalls main.

MEDIUM — VolumeController.swift:781: synchronous AppleScript getVolume per tick on AppleScript method.

MEDIUM — CustomModeSettingsView.swift:156-166: profile index OOB crash on removal with stale index.

LOW — CustomModeEngine.swift:184/193: KVO/notification observers never removed; shutdown() never invalidates.

LOW — PowerMateUSBTransport.swift:116: reportBuffer never freed; input callback never unregistered in stop().

LOW — OSDOverlay.swift:87: first! force-unwrap headless crash.