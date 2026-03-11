# PowerMateReborn — Documentation Index

## Project Structure
```
PowerMateDriver/
├── Package.swift
├── TODO.md                                Master task list
├── README.md                              Project overview + quick start
├── docs/
│   ├── README.md                          ← you are here
│   ├── appcast.xml                        Sparkle update feed (GitHub Pages)
│   └── research/
│       ├── RESEARCH_AUDIO.md              Audio volume control strategies (7 tiers)
│       └── RESEARCH_BRIGHTNESS.md         Brightness control strategies (7 tiers)
├── scripts/
│   ├── build-dmg.sh                       Automated .dmg packaging
│   ├── appcast-template.xml               Sparkle appcast template
│   ├── CODE_SIGNING.md                    Code signing + notarization guide
│   └── SPARKLE_SETUP.md                   Sparkle EdDSA + GitHub Pages guide
└── Sources/
    ├── main.swift                         App entry point
    ├── AppDelegate.swift                  Menu bar app, mode routing, gestures
    ├── PowerMateHID.swift                 IOKit HID driver, gesture + release detection
    ├── VolumeController.swift             Multi-tier audio volume engine
    ├── BrightnessController.swift         Multi-display brightness (DDC/CI, gamma, overlay, sync)
    ├── DDCController.swift                Native IOKit DDC/CI for external monitors
    ├── MIDIController.swift               CoreMIDI virtual source, CC + notes
    ├── OSCController.swift                Open Sound Control UDP sender
    ├── CustomModeEngine.swift             Per-app profiles, action execution, extended press
    ├── CustomModeSettingsView.swift        SwiftUI settings window for Custom mode
    ├── OSDOverlay.swift                   Native volume/brightness HUD overlay
    └── MenuBarIcon.swift                  Custom mode-specific menu bar icons
```

## Quick Start
```bash
cd PowerMateDriver
swift build
swift run
```

## Gesture Map

| Gesture | Volume | Brightness | MIDI | Custom |
|---------|--------|------------|------|--------|
| **Rotate** | Adjust volume | Adjust brightness | Send MIDI CC | Per-profile action |
| **Tap** | Snap to 20% (toggle) | Snap to 15% (toggle) | Toggle note | Per-profile action |
| **Double-tap** | Mute / unmute | Sleep display | Toggle note | Per-profile action |
| **Long press** | Cycle mode | Cycle mode | Cycle mode | Per-profile action* |

*\*Custom profiles can override long press with a custom action or extended press (hold-to-sustain), which disables mode cycling from the knob while active.*

## Current Status
- **v1.0 (Core Build):** Complete -- HID, volume, brightness, MIDI, OSD, gestures, settings, LED
- **v1.1 (Polish):** Complete -- per-device audio routing memory, brightness warning, MIDI settings UI
- **v1.2 (DDC/CI):** Complete -- native hardware brightness for external monitors, hybrid gamma+DDC, rate limiting
- **v1.3 (Extended Brightness):** Complete -- overlay dimming, night mode, per-display preferences, multi-display sync
- **v2.0 (Custom Mode):** Complete -- per-app profiles, scroll/keyboard/media/MIDI/OSC actions, long press override, extended press (hold-to-sustain), settings window, OSC controller, Codable persistence
- **Deployment:** Sparkle integrated, .dmg script ready, awaiting code signing + notarization

## Key Design Decisions
1. **No kernel extension** -- pure userspace IOKit HID, works on macOS 13+
2. **Four modes** -- Volume / Brightness / MIDI / Custom, long-press to cycle
3. **Three gestures + release** -- tap (snap), double-tap (mute/sleep), long-press (cycle), button-release (extended press sustain)
4. **Adaptive audio** -- CoreAudio Master > Channel > VirtualMaster > AppleScript > Software fallback
5. **Multi-display brightness** -- syncs all monitors by default (relative offsets preserved), or individual control by mouse cursor
6. **DDC/CI + gamma hybrid** -- instant gamma feedback for smooth knob feel, queued DDC hardware changes in background
7. **MIDI virtual source** -- CoreMIDI, appears in any DAW as "PowerMate Knob"
8. **Custom mode engine** -- NSWorkspace frontmost app observer, per-app Codable profiles, 6 action types, extended press sustain
9. **OSC over UDP** -- Network.framework NWConnection, proper OSC message encoding
10. **LED follows level** -- brightness tracks current mode's value in real time
