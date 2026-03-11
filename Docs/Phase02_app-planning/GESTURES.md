# Button Gesture System

## Overview

The PowerMate has one button (press the knob down). We extract three distinct gestures from this single input using timing analysis. All thresholds and actions are user-configurable.

## Gesture Detection State Machine

```
                    buttonDown
                        │
                        ▼
                ┌───────────────┐
                │  BUTTON_DOWN  │
                │  start timer  │
                └───────┬───────┘
                        │
            ┌───────────┴───────────┐
            │                       │
     timer fires               buttonUp
     (≥ 500ms)              (< 500ms)
            │                       │
            ▼                       ▼
    ┌──────────────┐      ┌─────────────────┐
    │  LONG_PRESS  │      │  WAIT_DOUBLE    │
    │  fire event  │      │  start 300ms    │
    │  immediately │      │  tap window     │
    └──────────────┘      └────────┬────────┘
                                   │
                       ┌───────────┴───────────┐
                       │                       │
                 buttonDown               timer fires
               (within 300ms)            (no 2nd press)
                       │                       │
                       ▼                       ▼
               ┌──────────────┐      ┌─────────────────┐
               │  DOUBLE_TAP  │      │  SINGLE_PRESS   │
               │  fire event  │      │  fire event     │
               └──────────────┘      └─────────────────┘
```

### Timing Parameters (configurable)
| Parameter | Default | Range | Notes |
|-----------|---------|-------|-------|
| `longPressThreshold` | 500ms | 300–1000ms | How long to hold for long press |
| `doubleTapWindow` | 300ms | 150–500ms | Max gap between taps for double tap |

### Important: Single-Press Delay
Single press cannot be detected instantly — we must wait `doubleTapWindow` ms after button release to confirm no second tap is coming. This adds ~300ms latency to single press actions. This is the same trade-off macOS makes for double-click detection.

**If double-tap is disabled for a mode,** single press fires immediately on release (no delay).

## Default Action Mapping

### Volume Mode
| Gesture | Default Action | Description |
|---------|---------------|-------------|
| Single press | `toggleMute` | Mute/unmute system audio |
| Double tap | `snapToValue(0.20)` | Snap volume to 20%, tap again to restore |
| Long press | `cycleMode` | Switch to next enabled mode |

### Brightness Mode
| Gesture | Default Action | Description |
|---------|---------------|-------------|
| Single press | `sleepDisplay` | Put display to sleep |
| Double tap | `nightMode(0.15)` | Toggle software dim overlay at 15% brightness |
| Long press | `cycleMode` | Switch to next enabled mode |

### Custom Mode
| Gesture | Default Action | Description |
|---------|---------------|-------------|
| Single press | `none` | No action (user configures) |
| Double tap | `none` | No action (user configures) |
| Long press | `cycleMode` | Switch to next enabled mode |

## Snap-to-Value Toggle Behavior

The `snapToValue` and `nightMode` actions are **toggles**:

1. **First activation:** Save current level → set to snap value
2. **Second activation:** Restore saved level

```
State: NORMAL, savedLevel = nil

  Double tap →
    savedLevel = currentVolume (e.g., 0.75)
    setVolume(0.20)
    State: SNAPPED

  Double tap again →
    setVolume(savedLevel)  // restore to 0.75
    savedLevel = nil
    State: NORMAL
```

**Edge cases:**
- If user adjusts volume while snapped (rotates knob), the snap state is cleared — the user has taken manual control
- If mode is switched while snapped, snap state is preserved and restored when returning to that mode

## Action Registry

All actions are registered in a central registry. Each action has:
- A unique string ID
- A display name (for settings UI)
- An execution function
- Optional parameters (e.g., snap value)

### Built-in Actions
| ID | Name | Parameters | Notes |
|----|------|-----------|-------|
| `toggleMute` | Toggle Mute | — | Volume mode only |
| `sleepDisplay` | Sleep Display | — | Any mode |
| `cycleMode` | Cycle Mode | — | Global |
| `snapToValue` | Snap to Value | `value: Float` | Toggle, per-mode |
| `nightMode` | Night Mode | `value: Float` | Overlay dim, toggle |
| `none` | Do Nothing | — | Explicitly no action |

### Future Actions
| ID | Name | Notes |
|----|------|-------|
| `playPause` | Play/Pause Media | Media key simulation |
| `nextTrack` / `prevTrack` | Next/Previous Track | Media key simulation |
| `sendKeystroke` | Send Keystroke | Configurable key combo |
| `scroll` | Scroll | Mouse wheel emulation |
| `midiCC` | Send MIDI CC | For DAW integration |
| `launchApp` | Launch App | Open a specific application |
| `shellCommand` | Run Shell Command | Power user feature |

## Implementation Notes

### Extracting GestureInterpreter from PowerMateHID
Currently, long-press detection lives inside `PowerMateHID`. This should be refactored:

```swift
// PowerMateHID sends raw events:
protocol PowerMateRawDelegate {
    func powerMateButtonDown()
    func powerMateButtonUp()
    func powerMateDidRotate(delta: Int)
}

// GestureInterpreter converts to semantic events:
protocol PowerMateGestureDelegate {
    func powerMateSinglePress()
    func powerMateDoubleTap()
    func powerMateLongPress()
    func powerMateDidRotate(delta: Int)  // pass-through
}
```

This separation keeps HID code clean and makes gesture detection testable independently.

### Double-Tap Detection Edge Cases
- **Fast triple tap:** Treated as double-tap + single-press
- **Long press after first tap:** If second press is held ≥ longPressThreshold, treat as single-press + long-press (not double-tap + long-press)
- **Rotation during press:** Does not affect gesture detection (rotation and button are independent HID inputs)
