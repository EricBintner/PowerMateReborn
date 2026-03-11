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
│   ├── Phase01_initial-build/
│   │   └── README.md                      Architecture, build instructions, known issues
│   ├── Phase02_app-planning/
│   │   ├── README.md                      Feature roadmap v1.0 → v2.0
│   │   ├── DESIGN_PLAN.md                 Interaction model, architecture, phases
│   │   ├── GESTURES.md                    Button gesture system
│   │   ├── RESEARCH_AUDIO.md              Audio volume control strategies (7 tiers)
│   │   └── RESEARCH_BRIGHTNESS.md         Brightness control strategies (7 tiers)
│   ├── Phase03_custom-control/
│   │   └── README.md                      Custom mode + MIDI research
│   └── Phase04_deployment--app-store/
│       └── README.md                      Distribution strategy
├── scripts/
│   ├── build-dmg.sh                       Automated .dmg packaging
│   ├── appcast-template.xml               Sparkle appcast template
│   └── SPARKLE_SETUP.md                   Sparkle EdDSA + GitHub Pages guide
└── Sources/
    ├── main.swift
    ├── AppDelegate.swift                  Menu bar app, mode routing, gestures
    ├── PowerMateHID.swift                 IOKit HID driver, gesture detection
    ├── VolumeController.swift             Multi-tier audio volume engine
    ├── BrightnessController.swift         DisplayServices + gamma + multi-display
    ├── MIDIController.swift               CoreMIDI virtual source, CC + notes
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

| Gesture | Volume | Brightness | MIDI |
|---------|--------|------------|------|
| **Rotate** | Adjust volume | Adjust brightness | Send MIDI CC |
| **Tap** | Snap to 20% (toggle) | Snap to 15% (toggle) | Toggle note |
| **Double-tap** | Mute / unmute | Sleep display | Toggle note |
| **Long press** | Cycle mode | Cycle mode | Cycle mode |

## Current Status
- **Phase 1 (Core Build):** Complete — HID, volume, brightness, MIDI, OSD, gestures, settings
- **Phase 2 (App Planning):** Complete — research docs, design plan, architecture
- **Phase 3 (Custom Control):** MIDI basic mode done, custom/OSC in v2.0
- **Phase 4 (Deployment):** Sparkle integrated, .dmg script ready, awaiting code signing

## Key Design Decisions
1. **No kernel extension** — pure userspace IOKit HID, works on macOS 13+
2. **Four modes** — Volume / Brightness / MIDI / Custom, long-press to cycle
3. **Three gestures** — tap (snap), double-tap (mute/sleep), long-press (cycle)
4. **Adaptive audio** — CoreAudio Master > Channel > VirtualMaster > AppleScript > Software fallback
5. **Multi-display brightness** — targets display under mouse cursor, gamma fallback for externals
6. **MIDI virtual source** — CoreMIDI, appears in any DAW as "PowerMate Knob"
7. **LED follows level** — brightness tracks current mode's value in real time
