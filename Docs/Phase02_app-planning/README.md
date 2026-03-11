# Phase 02: App Planning

## Status: Planning

## Vision
A polished, lightweight macOS menu bar app that turns the Griffin PowerMate into a multi-function controller. Simple by default (volume + brightness), extensible for power users (custom tool bindings).

## Interaction Design

### Knob Modes (cycle with long-press)
| Mode | Rotate | Short Press | Menu Bar Icon |
|------|--------|-------------|---------------|
| **Volume** | Adjust system volume | Toggle mute | 🔊 speaker.wave.2.fill |
| **Brightness** | Adjust screen brightness | Sleep display | ☀️ sun.max.fill |
| **Custom** | User-defined (scroll, zoom, etc.) | User-defined | 🎛️ slider.horizontal.3 |

### Button Behavior
- **Short press (<0.5s):** Mode-specific action (mute / sleep / custom)
- **Long press (≥0.5s):** Cycle to next enabled mode, LED flashes to confirm

### LED Behavior
- **Follow Level (default):** LED brightness tracks the current mode's level (volume %, brightness %)
- **Static:** User can set to Off / Dim / Bright / Pulse
- **Mode flash:** Quick double-flash on mode switch

## Planned Features

### v1.0 — Core (Phase 01, in progress)
- [x] HID device detection and input parsing
- [x] Volume control (CoreAudio + AppleScript fallback)
- [x] Mute toggle on button press
- [x] LED brightness control
- [x] Multi-mode architecture
- [x] Brightness mode with DisplayServices
- [x] Long-press mode cycling
- [ ] Persistent settings (UserDefaults)
- [ ] Launch at login (SMAppService)

### v1.1 — Polish
- [ ] Native macOS volume/brightness OSD overlay (the translucent HUD that appears when using keyboard keys)
- [ ] Audio device change listener (auto-switch CoreAudio ↔ AppleScript when devices change)
- [ ] Per-mode sensitivity settings
- [ ] Keyboard shortcut to switch modes
- [ ] About window with device info (firmware version, connection status)

### v1.2 — External Display Support
- [ ] DDC/CI brightness control for external monitors (LG, Dell, etc.)
- [ ] Multi-display support (control active display)
- [ ] Monitor volume via DDC (for monitors with speakers)

### v2.0 — Custom Mode (Phase 03)
- [ ] User-configurable actions per app (frontmost app detection)
- [ ] Scroll wheel emulation
- [ ] Zoom control
- [ ] Timeline scrubbing
- [ ] MIDI output for DAWs
- [ ] Keyboard shortcut binding

## Technical Decisions

### Why not a kernel extension?
Kernel extensions (kexts) are deprecated on macOS. The PowerMate is a standard USB HID device — macOS already provides `AppleUserHIDEventDriver`. We use IOKit's userspace HID API to read input reports directly. No driver installation needed.

### Why AppleScript fallback for volume?
Some audio devices (HDMI, virtual devices like Jump Desktop Audio) don't expose `kAudioDevicePropertyVolumeScalar` via CoreAudio. AppleScript's `set volume` command controls the system-level volume slider, which works for any device the OS recognizes.

### Why DisplayServices for brightness?
It's the same private framework that macOS uses internally for brightness keys. Works on Apple Silicon Macs with built-in displays. For external monitors, we'll need DDC/CI in v1.2.

## Target Compatibility
- **macOS:** 13.0+ (Ventura and later) — uses SF Symbols, modern AppKit
- **Hardware:** Griffin PowerMate USB (VID 0x077d, PID 0x0410)
- **Architecture:** Universal (Apple Silicon native, runs on Intel via Rosetta)
