# Phase 01: Initial Build

## Status: In Progress

## Goal
Get the Griffin PowerMate USB knob working as a volume/brightness controller on modern macOS (Sequoia+) with a native Swift menu bar app.

## Hardware
- **Device:** Griffin PowerMate (USB, silver knob)
- **Vendor ID:** `0x077d` / Product ID: `0x0410`
- **Protocol:** USB HID (Consumer Control)
- **Inputs:** Rotation (signed int8, -127 to +127), Button (1 bit)
- **Outputs:** LED brightness (feature report, 8 bytes)
- **No kernel driver needed** — standard HID device, macOS loads `AppleUserHIDEventDriver` automatically

## Architecture

```
┌──────────────────────────┐
│    PowerMateDriver App   │  (menu bar, no dock icon)
├──────────────────────────┤
│  AppDelegate             │  mode switching, menu UI, event routing
│  ├─ PowerMateHID         │  IOKit HID: read knob, write LED
│  ├─ VolumeController     │  CoreAudio / AppleScript fallback
│  └─ BrightnessController │  DisplayServices private framework
└──────────────────────────┘
```

## Interaction Model
- **Rotate** → adjust level (volume or brightness, depending on mode)
- **Short press** → mode action (mute for volume, display sleep for brightness)
- **Long press (≥0.5s)** → cycle to next enabled mode
- **LED** → follows current level by default, configurable

## Files
| File | Purpose |
|------|---------|
| `Sources/main.swift` | App entry point, menu-bar-only activation policy |
| `Sources/AppDelegate.swift` | Mode management, menu bar UI, event routing |
| `Sources/PowerMateHID.swift` | IOKit HID manager, input parsing, LED control, long-press detection |
| `Sources/VolumeController.swift` | Volume get/set/mute — CoreAudio with AppleScript fallback |
| `Sources/BrightnessController.swift` | Brightness via DisplayServices private framework |
| `Package.swift` | Swift Package Manager config (macOS 13+, IOKit/CoreAudio/AppKit) |

## Known Issues / TODO
- [ ] Volume: default device (Jump Desktop Audio) has no volume control — AppleScript also returns `missing value`. Mac Studio Speakers (device 80) DO have CoreAudio volume but are currently at 0.00 / off
- [ ] Need audio device change listener to auto-switch when default output changes
- [ ] Brightness: DisplayServices loads but LG HDR 4K (HDMI) has no OS brightness control — need DDC/CI or software overlay
- [ ] Double-tap gesture not yet implemented (see Phase02 GESTURES.md)
- [ ] No persistent settings yet (sensitivity, LED preference, enabled modes reset on restart)
- [ ] No launch-at-login support
- [ ] Custom mode is a placeholder

## Build & Run
```bash
cd PowerMateDriver
swift build
swift run
```
