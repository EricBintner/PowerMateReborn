# PowerMateReborn — Master TODO

> Last updated: March 2025

## Gesture Map

| Gesture | Volume Mode | Brightness Mode | MIDI Mode |
|---------|------------|-----------------|-----------|
| **Rotate** | Adjust volume | Adjust brightness | Send MIDI CC |
| **Tap** | Snap to 20% (toggle) | Snap to 15% / night (toggle) | Toggle note on/off |
| **Double-tap** | Mute / unmute | Sleep display | Toggle note on/off |
| **Long press** | Cycle to next mode | Cycle to next mode | Cycle to next mode |

## Completed

- [x] HID device detection & input parsing (IOKit)
- [x] Volume: CoreAudio Master + Channel + VirtualMaster + AppleScript + Software fallback
- [x] Volume: Mute toggle (hardware + simulated for devices without mute)
- [x] Volume: Device enumeration with full capability probing
- [x] Volume: Device change listener (default output + device list)
- [x] Volume: External volume/mute change listener (sync LED + UI)
- [x] Volume: L/R channel balance preservation
- [x] Volume: AppleScript rate limiting / debounce
- [x] Volume: Smart device fallback (auto-redirect to controllable device)
- [x] Volume: Audio device picker in menu bar
- [x] Brightness: DisplayServices private API (Apple displays)
- [x] Brightness: Gamma table fallback (external displays)
- [x] Brightness: Gamma restore on quit
- [x] Brightness: Gamma re-apply after display sleep/wake
- [x] Brightness: Multi-display targeting (controls display under mouse cursor)
- [x] LED brightness control + follow-level + static modes + pulse
- [x] 4-mode architecture: Volume / Brightness / MIDI / Custom
- [x] Gesture system: tap=snap, double-tap=mute/sleep, long-press=cycle mode
- [x] MIDI mode: CoreMIDI virtual source, CC on rotate, note on/off on press
- [x] Native OSD overlay (volume/brightness HUD with SF Symbols + segmented level bar)
- [x] Persistent settings (UserDefaults)
- [x] Sleep/wake handling (re-detect audio devices)
- [x] Custom menu bar icons (volume/brightness/custom/disconnected)
- [x] Sparkle auto-updater integration
- [x] Quick Start Guide dialog
- [x] Launch at Login (SMAppService)
- [x] About window with device diagnostics + GitHub Issues link
- [x] Automated .dmg build script
- [x] Sparkle appcast.xml + EdDSA setup guide
- [x] GitHub Pages configured for appcast hosting

---

## v1.1 Polish — Complete

- [x] **Per-device audio routing memory** — Saves "when default is X, control Y" in UserDefaults. Auto-applies on device change.
- [x] **Brightness warning indicator** — Shows "[Software]" suffix + warning triangle + explanation when gamma dimming is active.
- [x] **MIDI settings UI** — Submenu with CC number picker (Mod Wheel/Volume/Expression/Filter) and channel picker (1/2/10/16). Persisted.
- [ ] **DDC/CI toggle in UI** — Checkbox in settings to enable/disable DDC/CI. (Deferred to v1.2 when DDC is implemented.)

## v1.2 — DDC/CI Hardware Control (requires testing with LG monitor)

- [ ] **DDC/CI brightness** — Integrate AppleSiliconDDC library for real backlight control on external monitors (VCP 0x10).
- [ ] **DDC/CI volume** — Control monitor speaker volume via DDC (VCP 0x62) for HDMI/DP monitors.
- [ ] **DDC/CI rate limiter** — Queue + coalesce DDC commands (max 10/sec, monitors crash if flooded).
- [ ] **Hybrid brightness** — Instant gamma feedback + queued DDC hardware change for smooth knob feel.
- [ ] **DDC/CI display probing** — Auto-detect which monitors support DDC at startup, cache results.

## v1.3 — Extended Brightness

- [ ] **Overlay dimming** — NSWindow black overlay for DisplayLink displays or sub-zero dimming.
- [ ] **Night mode overlay** — Deep dim overlay for when gamma alone isn't dark enough.
- [ ] **Per-display preferences** — Remember brightness method + level per display (by serial number).

## v2.0 — Custom Mode (Phase 03)

- [ ] **User-configurable actions per app** — Frontmost app detection, per-app knob bindings.
- [ ] **Scroll wheel emulation** — Knob rotation sends scroll events.
- [ ] **MIDI/OSC advanced** — Per-app MIDI profiles, OSC output, advanced routing.

## Deployment

- [ ] **Code signing + notarization** — Requires Apple Developer account ($99/yr).
- [ ] **First .dmg release** — Build, sign, upload to GitHub Releases, update appcast.
- [ ] **GitHub Actions CI/CD** — Automated build + release workflow on tag push.
