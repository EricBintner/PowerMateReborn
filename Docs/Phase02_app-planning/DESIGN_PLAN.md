# PowerMate Driver — Design Plan

## 1. Product Vision

A lightweight, native macOS menu bar app that turns the Griffin PowerMate USB knob into a multi-function system controller. Ships with two core modes (Volume, Brightness) and an extensible Custom mode. All button gestures and actions are user-configurable.

**Design principles:**
- **Zero config to start:** Plug in, launch, turn the knob — volume works immediately
- **Progressive disclosure:** Simple defaults, power-user options available but not in the way
- **No kernel extensions:** Pure userspace, no installation beyond dragging the app

---

## 2. Interaction Model

### 2.1 Knob Rotation
Rotation adjusts the current mode's value. Each tick sends a signed delta (-127 to +127, typically ±1 for slow rotation, higher for fast spins).

| Mode | Rotation Effect |
|------|----------------|
| Volume | Adjust system output volume |
| Brightness | Adjust screen brightness |
| Custom | User-defined (scroll, zoom, MIDI CC, etc.) |

**Sensitivity:** Configurable step size per tick (1%, 3%, 5%, 8%). Could later be per-mode.

### 2.2 Button Gestures

Three distinct gestures, all configurable:

| Gesture | Detection | Default (Volume Mode) | Default (Brightness Mode) |
|---------|-----------|----------------------|--------------------------|
| **Single press** | Release < 300ms, no second press within 300ms | Toggle mute | Sleep display |
| **Double tap** | Two presses within 300ms | Snap to 20% volume (tap again to restore) | Night mode brightness (tap again to restore) |
| **Long press** | Hold ≥ 500ms | Cycle to next mode | Cycle to next mode |

**Key design decisions:**
- Single-press detection must wait ~300ms after release to distinguish from double-tap (this is the same pattern as macOS trackpad double-click detection)
- Long press fires immediately at threshold (don't wait for release)
- Double-tap "snap" values are configurable per mode
- Long press action is global (always cycles mode) unless user overrides

### 2.3 LED Behavior

| State | LED Effect |
|-------|-----------|
| Follow Level (default) | Brightness tracks current mode's level (0-100%) |
| Mode switch | Quick double-flash on transition |
| Muted / Sleep | LED off |
| Custom static | User sets Off / Dim / Bright / Pulse |

---

## 3. Configuration System

### 3.1 Settings Schema (UserDefaults, future: JSON config file)

```
powermate.currentMode: String = "volume"
powermate.enabledModes: [String] = ["volume", "brightness"]
powermate.stepSize: Float = 0.03
powermate.ledMode: String = "followLevel"  // followLevel | off | dim | bright | pulse
powermate.longPressThreshold: Float = 0.5
powermate.doubleTapInterval: Float = 0.3

powermate.volume.singlePress: String = "mute"
powermate.volume.doubleTap: String = "snapTo20"
powermate.volume.doubleTapValue: Float = 0.20
powermate.volume.longPress: String = "cycleMode"

powermate.brightness.singlePress: String = "sleepDisplay"
powermate.brightness.doubleTap: String = "nightMode"
powermate.brightness.doubleTapValue: Float = 0.15
powermate.brightness.longPress: String = "cycleMode"

powermate.custom.singlePress: String = "none"
powermate.custom.doubleTap: String = "none"
powermate.custom.longPress: String = "cycleMode"
```

### 3.2 Available Actions (extensible registry)
- `mute` — Toggle mute
- `sleepDisplay` — Put display to sleep
- `cycleMode` — Switch to next enabled mode
- `snapToValue` — Set level to a fixed value (toggle: tap again to restore previous)
- `nightMode` — Set brightness to night value (toggle)
- `none` — Do nothing
- *(Future: `sendMIDI`, `sendKeystroke`, `scroll`, `zoom`, etc.)*

---

## 4. Architecture

```
┌─────────────────────────────────────────────────┐
│                  AppDelegate                     │
│  ┌─────────────┐  ┌──────────────────────────┐  │
│  │ Menu Bar UI  │  │  GestureInterpreter      │  │
│  │ (NSMenu)     │  │  ├─ single press         │  │
│  └─────────────┘  │  ├─ double tap            │  │
│                    │  └─ long press            │  │
│  ┌─────────────┐  └──────────────────────────┘  │
│  │ ModeManager  │                                │
│  │ ├─ volume    │  ┌──────────────────────────┐  │
│  │ ├─ bright    │  │  ActionRegistry           │  │
│  │ └─ custom    │  │  maps gesture→action      │  │
│  └─────────────┘  └──────────────────────────┘  │
├─────────────────────────────────────────────────┤
│  PowerMateHID    │  VolumeController            │
│  (IOKit HID)     │  (CoreAudio + AppleScript)   │
│                  │  BrightnessController         │
│                  │  (DisplayServices + overlay)   │
└─────────────────────────────────────────────────┘
```

### 4.1 GestureInterpreter (new component)
Replaces the current long-press timer in PowerMateHID. Centralizes all button gesture detection:
- Receives raw `buttonDown` / `buttonUp` events from HID
- Emits semantic events: `singlePress`, `doubleTap`, `longPress`
- Configurable thresholds

### 4.2 ModeManager (refactor from AppDelegate)
- Owns the list of enabled modes and current mode
- Routes rotation/gesture events to the correct controller
- Handles mode cycling and LED updates

### 4.3 ActionRegistry (new component)
- Maps gesture+mode → action function
- User-configurable via settings
- Extensible: new actions register themselves

---

## 5. Implementation Phases

### Phase 1: Core (current — nearly complete)
- [x] HID device detection and input
- [x] Volume control (CoreAudio + AppleScript)
- [x] Brightness control (DisplayServices)
- [x] Long press mode cycling
- [x] LED control
- [ ] **Double-tap gesture detection**
- [ ] **Snap-to-value / night-mode toggle actions**
- [ ] Fix volume for current audio device situation
- [ ] Persistent settings (UserDefaults)

### Phase 2: Polish & Robustness
- [ ] Audio device change listener (auto-detect when default device switches)
- [ ] Refactor: extract GestureInterpreter, ModeManager, ActionRegistry
- [ ] Per-mode sensitivity settings
- [ ] Launch at login (SMAppService)
- [ ] Native macOS OSD overlay for volume/brightness changes
- [ ] About window

### Phase 3: Advanced Audio (see RESEARCH_AUDIO.md)
- [ ] Relative/virtual volume for non-controllable devices (HDMI, monitors)
- [ ] Monitor DDC/CI volume control
- [ ] Audio device picker in menu

### Phase 4: Advanced Brightness (see RESEARCH_BRIGHTNESS.md)
- [ ] Software dimming overlay for displays without brightness control
- [ ] DDC/CI brightness for external monitors
- [ ] Multi-display support

### Phase 5: Custom Mode (see Phase03_custom-control/)
- [ ] Scroll wheel emulation
- [ ] MIDI output
- [ ] Per-app profiles
- [ ] Keystroke binding
- [ ] Settings window UI

---

## 6. Compatibility Matrix

| macOS Version | Status |
|---------------|--------|
| 15.x Sequoia | Primary target |
| 14.x Sonoma | Should work (same APIs) |
| 13.x Ventura | Minimum target (SF Symbols, modern AppKit) |
| < 13 | Not supported |

| Audio Device Type | Volume Control Method |
|-------------------|---------------------|
| Built-in speakers | CoreAudio (kAudioDevicePropertyVolumeScalar) |
| USB audio | CoreAudio |
| Bluetooth | CoreAudio |
| HDMI (monitor) | None natively; future: DDC/CI or relative volume |
| Virtual (Jump Desktop, etc.) | AppleScript fallback; may return missing value |

| Display Type | Brightness Control Method |
|-------------|--------------------------|
| Built-in (MacBook) | DisplayServices private API |
| Apple external (Studio Display, etc.) | DisplayServices |
| Third-party external | Future: DDC/CI or software overlay |
