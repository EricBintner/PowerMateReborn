# Phase 03: Custom Control Research

## Status: Research Needed

## Overview
The "Custom" mode is a placeholder for user-configurable knob/button bindings. This phase requires UX research and prototyping before implementation.

## Research Areas

### 1. Pro Audio / DAW Integration
- **MIDI output:** PowerMate as a MIDI CC controller (e.g., fader, pan, send level)
  - CoreMIDI virtual source — DAWs see it as a MIDI device
  - Map rotation to CC messages, button to note on/off or transport control
  - Target apps: Logic Pro, Ableton Live, Pro Tools, Reaper
- **OSC output:** For apps that support Open Sound Control
- **HUI/Mackie Control:** Emulate a hardware control surface protocol

### 2. Video / Motion Graphics
- **Timeline scrubbing:** Send left/right arrow keys or J/K/L transport keys
  - Target apps: Final Cut Pro, DaVinci Resolve, Premiere Pro, After Effects
- **Zoom in/out:** Cmd+/Cmd- or scroll wheel emulation
- **Playback speed:** Variable speed shuttle control

### 3. General Productivity
- **Scroll wheel emulation:** Vertical or horizontal scroll
- **Zoom:** Pinch-zoom emulation (Cmd+scroll)
- **Tab switching:** Cycle browser tabs or app windows
- **Undo/Redo:** Cmd+Z / Cmd+Shift+Z on rotation
- **Keyboard shortcuts:** Arbitrary key combos on rotation/press

### 4. System Controls
- **Keyboard backlight:** Adjust keyboard illumination
- **Mission Control:** Trigger Exposé / Spaces
- **Media playback:** Play/pause, next/previous track (rotation = skip, press = play/pause)

## UX Questions to Resolve
1. **Per-app profiles?** Auto-switch based on frontmost app, or manual mode only?
2. **Configuration UI?** Menu bar submenu vs. a settings window?
3. **Presets?** Ship built-in profiles (e.g., "Logic Pro", "Video Editor", "Browser")?
4. **Rotation mapping:** Linear (1:1 ticks to actions) vs. acceleration (faster spin = bigger jumps)?
5. **Button combos?** Press+rotate for a different action than rotate alone?

## Technical Approaches

### Keyboard/Mouse Simulation
- `CGEvent` API for synthetic key presses and mouse events
- Requires Accessibility permissions (System Settings > Privacy > Accessibility)

### MIDI Output
- `CoreMIDI` framework — create a virtual MIDI source
- No special permissions needed
- DAWs auto-discover virtual MIDI ports

### Per-App Detection
- `NSWorkspace.shared.frontmostApplication` to detect active app
- `NSWorkspace.didActivateApplicationNotification` to listen for app switches
- Map bundle identifiers to profiles

### Configuration Persistence
- `UserDefaults` for simple key-value settings
- JSON config file for complex per-app profiles
- Consider a `~/.config/powermate/` directory for power users

## Priority Assessment
| Feature | Effort | Value | Priority |
|---------|--------|-------|----------|
| Scroll wheel emulation | Low | High | P1 |
| Media playback controls | Low | Medium | P1 |
| MIDI CC output | Medium | High (niche) | P2 |
| Per-app profiles | High | High | P2 |
| Timeline scrubbing | Medium | Medium (niche) | P3 |
| Settings window UI | High | Medium | P3 |

## Next Steps
1. User research: What does the user actually want to control?
2. Prototype scroll wheel emulation (simplest custom action)
3. Prototype MIDI output if pro audio is a priority
4. Design the configuration UI
