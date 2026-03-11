# PowerMate Driver — Documentation Index

## Project Structure
```
PowerMate/
├── Docs/
│   ├── README.md                          ← you are here
│   ├── Phase01_initial-build/
│   │   └── README.md                      Architecture, files, build instructions, known issues
│   ├── Phase02_app-planning/
│   │   ├── README.md                      Feature roadmap v1.0 → v2.0
│   │   ├── DESIGN_PLAN.md                 Full design plan: interaction model, architecture, phases
│   │   ├── GESTURES.md                    Button gesture system: single/double/long press detection
│   │   ├── RESEARCH_AUDIO.md              Audio volume strategies: CoreAudio, AppleScript, DDC/CI, virtual
│   │   └── RESEARCH_BRIGHTNESS.md         Brightness strategies: DisplayServices, DDC/CI, software overlay
│   └── Phase03_custom-control/
│       └── README.md                      Custom mode research: MIDI, DAW, scroll, per-app profiles
└── PowerMateDriver/
    ├── Package.swift
    └── Sources/
        ├── main.swift
        ├── AppDelegate.swift
        ├── PowerMateHID.swift
        ├── VolumeController.swift
        └── BrightnessController.swift
```

## Quick Start
```bash
cd PowerMateDriver
swift build
swift run
```

## Current Status
- **Phase 1 (Core Build):** ~80% complete — HID working, volume/brightness modes, long-press mode cycling
- **Phase 2 (App Planning):** Design docs written, double-tap gesture designed but not yet implemented
- **Phase 3 (Custom Control):** Research phase, not started

## Key Design Decisions
1. **No kernel extension** — pure userspace IOKit HID, works on macOS 13+
2. **Multi-mode knob** — long-press cycles between Volume / Brightness / Custom
3. **Three button gestures** — single press, double tap, long press (all configurable)
4. **Adaptive audio** — CoreAudio for real devices, AppleScript fallback, future DDC/CI
5. **LED follows level** — brightness tracks current mode's value by default
