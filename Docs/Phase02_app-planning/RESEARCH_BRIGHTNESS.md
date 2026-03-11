# Research: macOS Display Brightness Control — Comprehensive Strategy Guide

> **Scope:** macOS display brightness control for ALL display types — native Apple, third-party external, HDMI, DisplayPort, USB-C, and DisplayLink.  
> **Goal:** Industrial-strength brightness control that works for *every* display a user could connect to a Mac.  
> **Last updated:** March 2025

---

## Table of Contents

1. [The Problem Space](#the-problem-space)
2. [Display Taxonomy](#display-taxonomy)
3. [Control Strategy Matrix](#control-strategy-matrix)
   - Tier 1: DisplayServices Private API (Apple displays)
   - Tier 1b: CoreDisplay Private API
   - Tier 2: DDC/CI Hardware Brightness
   - Tier 3: Gamma Table Manipulation
   - Tier 4: Software Overlay Dimming
   - Tier 5: Simulated Brightness Keys
   - Tier 6: XDR/HDR Brightness Upscaling
   - Tier 7: Metal Shader Post-Processing
4. [DDC/CI Deep Dive](#ddcci-deep-dive)
5. [Display Detection & Routing Engine](#display-detection--routing-engine)
6. [Edge Cases & Failure Modes](#edge-cases--failure-modes)
7. [The LG HDR 4K Question](#the-lg-hdr-4k-question)
8. [Competitive Landscape](#competitive-landscape)
9. [Implementation Plan](#implementation-plan)
10. [Open Questions & Research Items](#open-questions--research-items)

---

## The Problem Space

Unlike volume (where the OS always *has* a concept of system volume), brightness on macOS is tightly coupled to the physical display hardware. macOS only natively controls brightness on:
- Built-in displays (MacBook, iMac)
- Apple-branded external displays (Studio Display, Pro Display XDR, Apple Thunderbolt Display)

For everything else — which is the **vast majority of external monitors** — macOS shows a grayed-out brightness slider and the F1/F2 keys do nothing. This is the reality for the user's Mac Studio + LG HDR 4K setup.

| Display Type | macOS Native Brightness? | Why |
|-------------|------------------------|-----|
| MacBook built-in | ✅ Yes | Apple controls the backlight via DisplayServices |
| iMac built-in | ✅ Yes | Same as MacBook |
| Apple Studio Display | ✅ Yes | Thunderbolt + proprietary protocol |
| Apple Pro Display XDR | ✅ Yes | Thunderbolt + proprietary + XDR API |
| LG UltraFine 5K/4K (Apple collab) | ✅ Yes | Special USB protocol (Apple partnership) |
| Third-party via HDMI | ❌ No | macOS sends digital signal, no brightness metadata |
| Third-party via DisplayPort | ❌ No | Same — digital passthrough |
| Third-party via USB-C/TB | ❌ No | Same (DP Alt Mode under the hood) |
| DisplayLink adapter | ❌ No | Virtual display — no DDC, no gamma manipulation |
| AirPlay/Sidecar display | ❌ No | Software display — no hardware brightness |

**The core insight:** For non-Apple external monitors, there are two fundamentally different approaches:
1. **Hardware control** — Send DDC/CI commands to change the monitor's actual backlight. True brightness. Saves power. Preserves colors. But requires monitor + connection support.
2. **Software simulation** — Manipulate what the GPU outputs (gamma tables, overlays) to *appear* dimmer. Works everywhere but doesn't change the backlight. Colors wash out toward black.

A robust product needs both, with seamless fallback.

---

## Display Taxonomy

### Connection Types & Brightness Capabilities

| Connection | DDC/CI? | DisplayServices? | Gamma? | Overlay? | Notes |
|-----------|---------|-----------------|--------|----------|-------|
| Built-in (Apple) | N/A | ✅ | ✅ | ✅ | Best supported |
| Thunderbolt (Apple display) | Proprietary | ✅ | ✅ | ✅ | Studio Display, etc. |
| USB-C / TB → DP Alt Mode | ✅ Usually | ❌ | ✅ | ✅ | **Most reliable DDC path** |
| HDMI (built-in port, M1) | ⚠️ Unreliable | ❌ | ✅ | ✅ | M1 HDMI→DP converter chip has DDC bugs |
| HDMI (built-in port, M2+) | ⚠️ Improved | ❌ | ✅ | ✅ | Better but still monitor-dependent |
| HDMI (built-in port, M3+) | ✅ Usually | ❌ | ✅ | ✅ | Best Apple Silicon HDMI DDC |
| DisplayPort (native) | ✅ Usually | ❌ | ✅ | ✅ | Most reliable for DDC |
| DisplayLink USB adapter | ❌ Never | ❌ | ❌ | ✅ | Only overlay works! |
| AirPlay / Sidecar | ❌ | ❌ | ❌ | ✅ | Software display, overlay only |

### Display Identification

```swift
// Enumerate all active displays
var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
var displayCount: UInt32 = 0
CGGetActiveDisplayList(16, &displayIDs, &displayCount)

// For each display, determine type:
// - CGDisplayIsBuiltin(displayID)          → true = MacBook/iMac built-in
// - CGDisplayIsInMirrorSet(displayID)      → mirror mode detection
// - CGDisplayModelNumber(displayID)        → hardware model
// - CGDisplayVendorNumber(displayID)       → 0x610 = Apple, others = third party
// - CGDisplaySerialNumber(displayID)       → unique per unit
// - IOServiceMatching("IODisplayConnect")  → IOKit service for DDC access
```

**Vendor IDs of interest:**
- `0x0610` (1552) = Apple
- `0x1E6D` (7789) = LG (also `0xGSM` in some cases)
- `0x10AC` (4268) = Dell
- `0x0469` (1129) = Samsung
- `0x0D32` (3378) = BenQ
- `0x0B05` (2821) = ASUS

---

## Control Strategy Matrix

### Tier 1: DisplayServices Private API ✅ IMPLEMENTED

**API:** `DisplayServicesGetBrightness()` / `DisplayServicesSetBrightness()`  
**Framework:** `/System/Library/PrivateFrameworks/DisplayServices.framework`

```swift
typealias GetBrightnessFunc = @convention(c) (UInt32) -> Float
typealias SetBrightnessFunc = @convention(c) (UInt32, Float) -> Void

let handle = dlopen(".../DisplayServices.framework/DisplayServices", RTLD_NOW)
let getBrightness = dlsym(handle, "DisplayServicesGetBrightness")
let setBrightness = dlsym(handle, "DisplayServicesSetBrightness")
```

**Works for:**
- MacBook / iMac built-in displays
- Apple Studio Display, Pro Display XDR
- LG UltraFine 5K/4K (Apple partnership models only)

**Does NOT work for:**
- Any third-party monitor (LG HDR 4K, Dell, Samsung, etc.)
- Returns 0.0 or -1.0 for unsupported displays
- On Mac Studio with no built-in display: no valid target

- **Precision:** Float 0.0–1.0 (smooth)
- **Latency:** < 5ms
- **Reliability:** Rock-solid on supported displays
- **Risk:** Private API — could break on any macOS update (but has been stable since macOS 10.12.4)
- **Status:** Implemented, working

### Tier 1b: CoreDisplay Private API ⚠️ NOT YET IMPLEMENTED

**API:** `CoreDisplay_Display_SetUserBrightness()` / `CoreDisplay_Display_GetUserBrightness()`  
**Framework:** `CoreDisplay.framework` (private, but loaded by default)

```swift
// CoreDisplay is a lower-level API than DisplayServices
// Available since macOS 10.12.4 (when Night Shift was added)
typealias SetUserBrightnessFunc = @convention(c) (CGDirectDisplayID, Double) -> Int32
typealias GetUserBrightnessFunc = @convention(c) (CGDirectDisplayID) -> Double
```

**Difference from DisplayServices:**
- `CoreDisplay` is the underlying framework that `DisplayServices` wraps
- May expose additional capabilities or work for displays that `DisplayServices` misses
- Used by some third-party tools as an alternative path

**Same limitations:** Only works on Apple-controlled displays. Not a path to third-party external monitors.

**Worth adding as:** A fallback if `DisplayServices` fails for a given display ID.

### Tier 2: DDC/CI Hardware Brightness 🔬 RESEARCH PHASE

**Protocol:** DDC/CI over I²C  
**VCP Code:** `0x10` (Luminance / Brightness, range 0–100)

This is the **most important tier for external monitors.** DDC/CI sends a command directly to the monitor's firmware to adjust its actual backlight. True brightness reduction — saves power, preserves color accuracy, reduces eye strain.

*See [DDC/CI Deep Dive](#ddcci-deep-dive) section below for full technical details.*

- **Precision:** Integer 0–100 (1% steps). Some monitors support finer via VCP code `0x12` (Luminance Fine)
- **Latency:** 50–200ms per command (I²C bus is slow)
- **Reliability:** Depends heavily on monitor + connection + Mac model
- **Status:** Not yet implemented

### Tier 3: Gamma Table Manipulation 🔬 RESEARCH PHASE

**API:** `CGSetDisplayTransferByFormula()` or `CGSetDisplayTransferByTable()`  
**Framework:** CoreGraphics (public, documented API)

Adjusts the GPU's gamma lookup table (LUT) for a specific display. By scaling down the gamma curve, the image appears dimmer. This is what **Lunar** calls "Software Dimming" and what **MonitorControl** offers as a fallback.

```swift
// Formula-based (simpler)
// min=0, max=brightness, gamma=1.0 gives linear dimming
CGSetDisplayTransferByFormula(
    displayID,
    0.0, brightness, 1.0,  // red:   min, max, gamma
    0.0, brightness, 1.0,  // green: min, max, gamma
    0.0, brightness, 1.0   // blue:  min, max, gamma
)

// To restore original:
CGDisplayRestoreColorSyncSettings()
```

```swift
// Table-based (more control, better quality)
var redTable   = [CGGammaValue](repeating: 0, count: 256)
var greenTable = [CGGammaValue](repeating: 0, count: 256)
var blueTable  = [CGGammaValue](repeating: 0, count: 256)

for i in 0..<256 {
    let normalized = Float(i) / 255.0
    let dimmed = normalized * brightness  // brightness = 0.0 to 1.0
    redTable[i]   = dimmed
    greenTable[i]  = dimmed
    blueTable[i]  = dimmed
}

CGSetDisplayTransferByTable(displayID, 256, &redTable, &greenTable, &blueTable)
```

**Pros:**
- ✅ Works on ANY display (including DisplayLink, AirPlay — NO, see caveat)
- ✅ No window creation — doesn't affect screenshots, screen recording, or screen sharing
- ✅ Per-display targeting — can dim one monitor without affecting others
- ✅ Public, documented API — won't break
- ✅ Can also do color temperature shifts (warm/cool, Night Shift equivalent)
- ✅ Works in fullscreen apps and games
- ✅ Smooth transitions possible (animate the table over frames)

**Cons:**
- ❌ Doesn't reduce backlight — screen still at full power, just showing a darker image
- ❌ Colors wash out toward black (reduced dynamic range)
- ❌ Conflicts with f.lux, Night Shift, and other gamma-modifying apps — they'll overwrite each other
- ❌ macOS may reset gamma tables on display sleep/wake, display reconfiguration
- ❌ Doesn't work on DisplayLink displays (DisplayLink bypasses the GPU gamma path)
- ❌ Some fullscreen games may reset gamma tables

**Rate limiting:** Gamma table updates are very fast (< 1ms). Safe to call at 60Hz for smooth knob tracking.

**Reset handling:** Must re-apply gamma after sleep/wake. Listen for:
- `CGDisplayRegisterReconfigurationCallback` — display reconfiguration events
- `NSWorkspace.didWakeNotification` — sleep/wake

### Tier 4: Software Overlay Dimming 🔬 RESEARCH PHASE

**API:** `NSWindow` with black background + variable opacity  
**Framework:** AppKit (public API)

Create an invisible, click-through black window over the entire screen. Adjust opacity to simulate dimming.

```swift
let overlay = NSWindow(
    contentRect: screen.frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
overlay.backgroundColor = NSColor.black.withAlphaComponent(dimLevel)
overlay.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
overlay.ignoresMouseEvents = true           // click-through
overlay.collectionBehavior = [
    .canJoinAllSpaces,                      // all Spaces/desktops
    .stationary,                            // doesn't move with Space switches
    .fullScreenAuxiliary                    // shows on fullscreen spaces
]
overlay.hasShadow = false
overlay.isOpaque = false
overlay.orderFrontRegardless()
```

**Pros:**
- ✅ Works on literally ANY display — including DisplayLink (the ONLY method that works there)
- ✅ No private APIs, no drivers, no special permissions
- ✅ Can go darker than gamma (gamma can't go below min, but overlay can reach near-black)
- ✅ Simple implementation
- ✅ Can stack with gamma for even deeper dimming

**Cons:**
- ❌ Affects screenshots — black overlay appears in screenshots and screen recordings
- ❌ May conflict with some fullscreen apps (though `fullScreenAuxiliary` helps)
- ❌ Window management overhead
- ❌ Doesn't reduce backlight
- ❌ Colors shift to black (same as gamma, but more so)
- ❌ macOS Sequoia `fullScreenAuxiliary` behavior changed — some reports of issues above fullscreen windows
- ❌ App Store sandbox forbids `CGShieldingWindowLevel` (our app is distributed outside App Store, so OK)

**Best for:**
- **DisplayLink displays** (only option)
- **Night mode / emergency dimming** — double-tap to dim to near-black
- **Below-zero dimming** — when the monitor's minimum brightness is still too bright (late night use)

### Tier 5: Simulated Brightness Keys ⚠️ LIMITED VALUE

**API:** `NSEvent.otherEvent(with: .systemDefined, ...)` via CGEvent  
**Key codes:** `NX_KEYTYPE_BRIGHTNESS_UP` (keycodes 107 / 113 for F1/F2)

Simulates pressing the physical F1/F2 brightness keys on an Apple keyboard.

```swift
// Method 1: Key code simulation
let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 107, keyDown: true)  // F14 = brightness down
let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 107, keyDown: false)
keyDown?.post(tap: .cghidEventTap)
keyUp?.post(tap: .cghidEventTap)

// Method 2: NX_KEYTYPE system event (same as media keys for volume)
let code: Int32 = 3  // NX_KEYTYPE_BRIGHTNESS_DOWN
// ... same pattern as volume media key simulation
```

**Works for:** Only displays where macOS brightness keys already work (Apple displays).

**Does NOT help for:** External third-party monitors — if macOS can't control them natively, simulating the key press won't help either.

- **Precision:** 1/16 steps (6.25% per key event)
- **Latency:** < 5ms
- **Coverage:** Only Apple/built-in displays
- **OSD:** Shows native brightness HUD

**Verdict:** Very limited value. Only useful as a fallback on built-in displays where `DisplayServices` fails (unlikely scenario). Not useful for external monitors.

### Tier 6: XDR/HDR Brightness Upscaling ⚠️ NICHE

**Concept:** On Apple XDR displays (MacBook Pro 14"/16", Pro Display XDR), the display can go beyond standard 500 nits up to 1000–1600 nits. BetterDisplay and Lunar can unlock this.

**API:** Uses private CoreDisplay APIs + specific entitlement flags.

**Relevant VCP-like properties:**
- Standard SDR max: ~500 nits
- XDR sustained full-screen: ~1000 nits  
- XDR peak HDR: ~1600 nits

**Not relevant for us now** — the user's LG HDR 4K is not an Apple XDR display. But worth noting for future MacBook users who want PowerMate to control "super brightness."

### Tier 7: Metal Shader Post-Processing 🔬 FUTURE

**Concept:** Use a Metal compute shader or Core Image filter to post-process the display output, applying brightness/contrast/color adjustments at the GPU level.

This is an emerging approach used by some newer apps:
- **BetterDisplay** uses Metal as an alternative to gamma tables on Apple Silicon
- Avoids gamma table conflicts with Night Shift / f.lux
- Can do more sophisticated adjustments (tone mapping, HDR simulation)

**Pros:**
- ✅ Doesn't conflict with gamma table users
- ✅ More flexible than gamma (can do HDR tone mapping, local dimming simulation)
- ✅ Works on Apple Silicon natively

**Cons:**
- ❌ Complex implementation
- ❌ Requires understanding of Metal compute pipelines
- ❌ May have performance implications
- ❌ Not well documented for this use case

**Verdict:** Future option (v3.0+). Gamma tables are simpler and sufficient for now.

---

## DDC/CI Deep Dive

DDC/CI is the most important technology for controlling external monitors. Here's everything we need to know.

### Protocol Overview

```
┌──────────────┐    I²C bus     ┌──────────────────┐
│  Mac GPU     │◄──────────────►│  Monitor MCU     │
│              │  (over HDMI/   │  (firmware)       │
│              │   DP signal)   │                   │
└──────────────┘                └──────────────────┘

DDC/CI (Display Data Channel / Command Interface)
  └── MCCS (Monitor Control Command Set)
        └── VCP (Virtual Control Panel) codes
              ├── 0x10: Brightness (Luminance)     ← We need this
              ├── 0x12: Contrast
              ├── 0x62: Audio Speaker Volume        ← Also useful (see audio research)
              ├── 0x60: Input Source Select
              ├── 0xD6: Power Mode
              └── 0xDC: Display Mode (color preset)
```

### VCP Code 0x10 (Brightness) Details

- **Range:** 0–100 (integer, percentage of max backlight)
- **Read:** Send GET VCP Feature (0x10), monitor returns current + max values
- **Write:** Send SET VCP Feature (0x10, value)
- **Response time:** 50–200ms per command depending on monitor
- **Monitor OSD:** Many monitors briefly show their own brightness OSD when DDC changes brightness

### Apple Silicon DDC/CI Implementation

On Apple Silicon, the GPU architecture changed completely from Intel. The IOKit service path for I²C access is different:

| Era | IOKit Service | I²C Access Method | Status |
|-----|--------------|-------------------|--------|
| Intel Macs | `IOFramebuffer` | `IOFBCopyI2CInterfaceForBus()` | Works, well documented |
| M1 (all) | `IOMobileFramebuffer` / `AppleCLCD2` | Private IOKit calls | ⚠️ Complex, unreliable on HDMI |
| M2+ | `IOMobileFramebuffer` / `AppleCLCD2` | Same private path, improved | ✅ Better reliability |
| M3+ | Same | Same path, further improved | ✅ Best support |

**The definitive Swift library:** [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC) by @waydabber (BetterDisplay author)
- Open source, MIT-like license
- Swift Package Manager compatible
- Handles both USB-C/DP and HDMI DDC paths
- Used by MonitorControl and BetterDisplay
- **Note:** The open-source version may be missing some M1 HDMI-specific fixes that exist in BetterDisplay's closed-source version

**Alternative CLI tools:**
- [`m1ddc`](https://github.com/waydabber/m1ddc) — Simple CLI: `m1ddc set brightness 50 -d 1`
- Only supports USB-C/DisplayPort Alt Mode connections (NOT built-in HDMI)
- Good for quick testing: `m1ddc display list` to see what's detected

### DDC/CI Compatibility Matrix

| Monitor Brand | DDC/CI Support | HDMI | DP/USB-C | Notes |
|--------------|---------------|------|----------|-------|
| **LG** (standard) | ✅ Usually | ✅ Most models | ✅ | LG generally excellent DDC support |
| **LG** (OLED/TV) | ❌ | ❌ | ❌ | LG TVs use HDMI-CEC, NOT DDC |
| **Dell** | ✅ Usually | ✅ | ✅ | Very reliable DDC |
| **BenQ** | ✅ Usually | ✅ | ✅ | Good support |
| **ASUS** | ⚠️ Varies | ⚠️ | ✅ | Some models need DDC enabled in OSD |
| **Samsung** | ⚠️ Varies | ⚠️ | ⚠️ | Budget models often lack DDC |
| **AOC** | ⚠️ | ⚠️ | ⚠️ | Varies widely |
| **Acer** | ⚠️ | ⚠️ | ✅ | Mid-range and up usually OK |
| **Apple** | N/A | N/A | N/A | Uses proprietary protocol, not DDC |
| **Budget/generic** | ❌ Often not | ❌ | ❌ | May lack DDC entirely |

### DDC Rate Limiting (Critical)

Monitors have a slow I²C bus and limited firmware. Sending DDC commands too fast can:
1. **Overload the monitor's MCU** — commands get dropped silently
2. **Cause the monitor to hang** — requiring power cycle
3. **Produce flickering** — backlight adjusts in visible steps

**Recommended limits:**
- **Writes:** Max 5–10/sec (100–200ms between commands)
- **Reads:** Max 2–5/sec (reads are slower due to response wait)
- **After a write:** Wait at least 50ms before issuing another command
- **For smooth knob rotation:** Queue + coalesce. Only send the final value after user pauses or at fixed intervals.

### DDC/CI Implementation Strategy

```swift
// Proposed DDCBrightnessController architecture:

class DDCBrightnessController {
    private let ddcQueue = DispatchQueue(label: "ddc.brightness")
    private var lastSendTime: TimeInterval = 0
    private let minInterval: TimeInterval = 0.1  // 100ms
    private var pendingValue: Int?
    private var coalesceTimer: Timer?
    
    func setBrightness(_ value: Int) {  // 0–100
        pendingValue = value
        scheduleCoalescedSend()
    }
    
    private func scheduleCoalescedSend() {
        coalesceTimer?.invalidate()
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: minInterval, repeats: false) { _ in
            if let value = self.pendingValue {
                self.ddcQueue.async {
                    self.sendDDCCommand(vcp: 0x10, value: UInt16(value))
                }
                self.pendingValue = nil
            }
        }
    }
}
```

---

## Display Detection & Routing Engine

### Current Implementation (Simplified)
```
1. Get CGMainDisplayID()
2. Call DisplayServicesSetBrightness()
3. Hope for the best
```

### Proposed Robust Implementation

```
                    ┌──────────────────────────┐
                    │   Display Change Event    │
                    │ (CGDisplayReconfiguration │
                    │  Callback)                │
                    └────────────┬─────────────┘
                                 ▼
                    ┌──────────────────────────┐
                    │   Enumerate All Displays  │
                    │   CGGetActiveDisplayList   │
                    └────────────┬─────────────┘
                                 ▼
                    ┌──────────────────────────┐
                    │   For Each Display:       │
                    │   • Vendor ID             │
                    │   • Is built-in?          │
                    │   • Connection type        │
                    │   • DDC/CI probe           │
                    │   • DisplayServices probe  │
                    └────────────┬─────────────┘
                                 ▼
              ┌──────────────────┼───────────────────┐
              ▼                  ▼                    ▼
     ┌────────────────┐ ┌───────────────┐ ┌──────────────────┐
     │ Apple/Built-in  │ │ External +    │ │ External, no     │
     │ Display         │ │ DDC/CI works  │ │ DDC/CI           │
     └───────┬────────┘ └──────┬────────┘ └────────┬─────────┘
             ▼                 ▼                    ▼
     ┌────────────────┐ ┌───────────────┐ ┌──────────────────┐
     │ Tier 1:        │ │ Tier 2:       │ │ Tier 3/4:        │
     │ DisplayServices│ │ DDC/CI        │ │ Gamma or Overlay  │
     └────────────────┘ └───────────────┘ └──────────────────┘
```

### Multi-Display Awareness

The PowerMate knob should control the "active" display. Options:

1. **Frontmost display** — The display containing the mouse cursor
   - `NSEvent.mouseLocation` → find which `NSScreen` contains it
   - Most intuitive for multi-monitor setups

2. **Primary display** — Always control the main display
   - `CGMainDisplayID()`
   - Simpler, but less useful with multiple monitors

3. **User-selected display** — Pin a specific display in the menu
   - Best for power users with fixed setups
   - Remember selection via `CGDisplaySerialNumber` (persists across reboots)

4. **All displays** — Adjust all displays simultaneously
   - Useful for matching brightness across monitors
   - Must handle different brightness ranges per display

**Recommended default:** Frontmost display (mouse cursor), with menu option to pin or sync all.

### Display Change Listener

```swift
func registerDisplayChangeListener() {
    CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
        if flags.contains(.addFlag) {
            // New display connected
        }
        if flags.contains(.removeFlag) {
            // Display disconnected
        }
        if flags.contains(.setMainFlag) {
            // Main display changed
        }
        // Re-probe all displays
        self.refreshDisplayCapabilities()
    }, nil)
}
```

**Additional notifications:**
- `NSApplication.didChangeScreenParametersNotification` — display layout changed
- `NSWorkspace.didWakeNotification` — re-probe after sleep (DDC state may be lost)

---

## Edge Cases & Failure Modes

### 1. No Built-in Display (Mac Studio, Mac Pro, Mac mini)
**Problem:** `DisplayServicesSetBrightness(CGMainDisplayID())` does nothing because the main display is an external monitor.  
**Solution:** Detect `CGDisplayIsBuiltin() == false` for all displays. Skip Tier 1, go directly to DDC/CI or gamma.

### 2. DDC/CI Probe Fails but Monitor Actually Supports It
**Problem:** First DDC read times out (monitor in sleep mode, slow firmware init). App concludes DDC isn't supported.  
**Solution:** Retry DDC probe 2–3 times with exponential backoff. Cache results but allow manual "re-detect" from menu.

### 3. DDC Commands Crash Monitor Firmware
**Problem:** Sending DDC too fast causes monitor MCU to hang. Screen goes black or freezes.  
**Solution:** Strict rate limiting (see DDC Rate Limiting above). Never send more than 10 commands/sec. Add a configurable delay setting for problematic monitors.

### 4. Gamma Table Conflict with Night Shift / f.lux
**Problem:** Both our app and Night Shift write to the gamma table. They overwrite each other on every update.  
**Solution:** 
- Read current gamma state before modifying. Apply our dimming ON TOP of existing values (multiplicative, not replace).
- Listen for `kCGDisplaySetModeFlag` to detect when another app changes gamma.
- Better: Use Tier 2 (DDC) for hardware brightness, reserve gamma only as a fallback.
- Warn user if gamma conflict detected.

### 5. Display Sleep Resets Gamma
**Problem:** When a display sleeps and wakes, macOS resets its gamma tables to system defaults.  
**Solution:** Listen for `CGDisplayRegisterReconfigurationCallback`. Re-apply gamma after wake.

### 6. Overlay Appears in Screenshots
**Problem:** `NSWindow` overlay at high window level is captured by `screencapture`, Cmd+Shift+3/4, and screen recording.  
**Solution:** 
- Use `window.sharingType = .none` (macOS 10.10+) — excludes from screen sharing/recording
- For screenshots: Unfortunately no clean workaround with overlay approach. This is why **gamma is preferred over overlay** for general use.

### 7. Fullscreen Apps Hide Overlay
**Problem:** Some fullscreen apps (especially games) can push above the overlay window level.  
**Solution:** 
- Use `CGShieldingWindowLevel()` or `CGWindowLevelForKey(.maximumWindow)`
- Add `.fullScreenAuxiliary` to `collectionBehavior`
- Gamma tables DON'T have this problem (they operate at GPU level, below windowing)

### 8. Multiple Displays at Different Brightness Ranges
**Problem:** Monitor A supports brightness 0–100. Monitor B supports 30–100 (minimum backlight = 30%). PowerMate at 0% should mean "minimum" for each, not absolute 0.  
**Solution:** Read DDC min/max values per display. Map PowerMate's 0.0–1.0 range to each display's actual range.

### 9. Rapid Knob Rotation + Slow DDC
**Problem:** Fast knob rotation generates dozens of brightness change requests. DDC can only handle ~10/sec.  
**Solution:** Coalesce/debounce (same as volume). Show immediate feedback via gamma dimming, then catch up with DDC hardware change. This gives "instant feel" + "real hardware change."

### 10. Display Disappears Mid-Adjustment
**Problem:** Monitor turned off, cable unplugged, or Bluetooth display disconnected while adjusting.  
**Solution:** Wrap all display operations in error handling. If a display disappears, fall back to next available display. Show brief notification.

### 11. HDR Content vs. Brightness
**Problem:** On HDR displays, system brightness interacts with HDR tone mapping. Lowering brightness may crush HDR highlights.  
**Solution:** For HDR-capable displays, use DDC (which adjusts backlight, preserving HDR). Avoid gamma manipulation on HDR displays as it distorts the tone map.

### 12. DisplayLink Displays
**Problem:** DisplayLink adapters create virtual displays. No DDC, no gamma table access. Only overlay works.  
**Solution:** Detect DisplayLink displays (vendor ID or `IODisplayConnect` service matching). Auto-select overlay mode. Warn user that only software dimming is available.

---

## The LG HDR 4K Question

The user has an **LG HDR 4K** monitor connected via **HDMI** to a **Mac Studio**.

### What We Know
- LG standard monitors (non-TV, non-OLED) generally have **excellent DDC/CI support**
- The "HDR 4K" designation suggests a model from the LG UK/UL/UP/UN series (e.g., 27UK850, 27UL850, 27UP850)
- These models are widely confirmed to support DDC/CI for brightness, contrast, and volume
- LG's On Screen Control software uses DDC/CI internally

### The HDMI + Mac Studio Variable
- Mac Studio (M1 Max/Ultra) has a built-in HDMI 2.0 port that internally converts DP→HDMI via a converter chip
- This converter chip has **known DDC/CI reliability issues** on M1-era hardware
- BetterDisplay v3.x claims to have solved this with a special DDC implementation for M1 HDMI

### Testing Plan
1. **Quick test:** Install MonitorControl (free) → Does brightness slider appear for the LG?
2. **CLI test:** `brew install m1ddc && m1ddc display list` → Does it detect the LG? (Note: m1ddc may NOT detect HDMI-connected displays)
3. **Definitive test:** Install BetterDisplay trial → It has the most complete M1 HDMI DDC implementation
4. **If DDC works over HDMI:** Great — we can use AppleSiliconDDC library
5. **If DDC fails over HDMI:** Two options:
   - Recommend USB-C → HDMI cable (DP Alt Mode, DDC works reliably)
   - Fall back to gamma table dimming

### Most Likely Outcome
**DDC/CI will probably work for the LG HDR 4K**, either directly over HDMI (if BetterDisplay's M1 HDMI fix applies) or by switching to a USB-C connection. LG monitors are among the most DDC-compatible displays on the market.

---

## Competitive Landscape

| App | DDC | Gamma | Overlay | XDR | Multi-display | Free | Notes |
|-----|-----|-------|---------|-----|--------------|------|-------|
| **macOS built-in** | ❌ | ❌ | ❌ | ✅ | ❌ | ✅ | Apple displays only |
| **MonitorControl** (free) | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | Open source, mature, best free option |
| **Lunar** ($23) | ✅ | ✅ | ❌ | ✅ | ✅ | ❌ | Best DDC on Apple Silicon, smart features |
| **BetterDisplay** ($18) | ✅ | ✅ | ❌ | ✅ | ✅ | ❌ | Only app with M1 HDMI DDC support |
| **DisplayBuddy** ($8) | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ | Simple DDC, native UI |
| **Gamma Dimmer** (free) | ❌ | ✅ | ✅ | ❌ | ✅ | ✅ | Gamma + overlay fallback |
| **f.lux** (free) | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | Color temperature only, not brightness |
| **Vivid** ($20) | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | XDR upscaling only |

**Our differentiator:** We're not a brightness control app — we're a **hardware knob** that makes brightness adjustable with a physical dial. The emphasis is on feel: smooth, instant response, zero-config. The brightness engine needs to "just work" when you turn the knob.

---

## Implementation Plan

### Phase A: Harden Existing + Gamma Fallback (v1.1) — Estimated: 1 week

| # | Task | Priority | Effort | Deps |
|---|------|----------|--------|------|
| A1 | **Display enumeration** — On startup + display change, enumerate all displays. Cache vendor, built-in flag, connection type for each. | 🔴 High | Small | None |
| A2 | **Display change listener** — Register `CGDisplayRegisterReconfigurationCallback`. Re-probe capabilities on connect/disconnect/wake. | 🔴 High | Small | None |
| A3 | **Multi-display targeting** — Control the display under the mouse cursor (frontmost), not just `CGMainDisplayID()`. | 🔴 High | Medium | A1 |
| A4 | **CoreDisplay fallback** — Try `CoreDisplay_Display_SetUserBrightness` if `DisplayServices` fails. | 🟡 Medium | Small | None |
| A5 | **Gamma table dimming** — Implement `CGSetDisplayTransferByFormula` as a fallback for displays without native or DDC control. | 🔴 High | Medium | A1 |
| A6 | **Gamma sleep/wake handling** — Re-apply gamma tables after display sleep/wake. | 🟡 Medium | Small | A5 |
| A7 | **Gamma conflict detection** — Read existing gamma before modifying. Apply multiplicatively to preserve Night Shift / f.lux. | 🟡 Medium | Medium | A5 |
| A8 | **Rate limiting** — Debounce brightness updates. Gamma: 60Hz OK. DDC: 10Hz max. | 🟡 Medium | Small | None |
| A9 | **Display picker menu** — Show all displays in menu bar with capability indicators and brightness levels. | 🟡 Medium | Medium | A1 |

### Phase B: DDC/CI Hardware Brightness (v1.2) — Estimated: 2–3 weeks

| # | Task | Priority | Effort | Deps |
|---|------|----------|--------|------|
| B1 | **Integrate AppleSiliconDDC** — Add the DDC library as a Swift package dependency. Implement basic read/write for VCP 0x10. | 🔴 High | Medium | None |
| B2 | **DDC display probing** — On startup, probe each external display for DDC/CI support. Cache results. | 🔴 High | Medium | B1 |
| B3 | **DDC rate limiter** — Queue + coalesce DDC commands. Max 10/sec. | 🔴 High | Small | B1 |
| B4 | **Hybrid brightness** — For DDC displays: show immediate gamma feedback + queued DDC hardware change. Best of both worlds. | 🟡 Medium | Medium | B1, A5 |
| B5 | **DDC retry logic** — If DDC write fails, retry once. If persistent failure, fall back to gamma. | 🟡 Medium | Small | B1 |
| B6 | **Test LG HDR 4K** — Verify DDC brightness works on user's specific monitor via HDMI. Document results. | 🔴 High | Small | B1 |
| B7 | **DDC contrast control** — Optional: VCP 0x12 for contrast. Could be a hold+rotate gesture. | 🟢 Low | Small | B1 |
| B8 | **Custom brightness OSD** — For DDC changes (which don't trigger native OSD), show a native-looking brightness HUD. | 🟡 Medium | Medium | B1 |

### Phase C: Polish & Universal (v1.3+) — Estimated: 1–2 weeks

| # | Task | Priority | Effort | Deps |
|---|------|----------|--------|------|
| C1 | **Overlay dimming** — Implement NSWindow overlay for DisplayLink displays or sub-zero dimming. | 🟡 Medium | Small | None |
| C2 | **Night mode** — Double-tap to toggle deep dimming (overlay to ~15%). Works on any display. | 🟡 Medium | Small | C1 |
| C3 | **Per-display preferences** — Remember preferred brightness method + level per display (by serial number). | 🟡 Medium | Small | A1 |
| C4 | **Brightness sync** — Option to synchronize brightness across all connected displays. | 🟢 Low | Medium | A1, B1 |
| C5 | **Color temperature** — Optional: warm/cool shift via gamma table. Alternative to Night Shift. | 🟢 Low | Medium | A5 |

### Fallback Chain (Final Architecture)

```
PowerMate knob rotation (brightness mode)
  │
  ▼
┌──────────────────────────────────────────────────────┐
│ Brightness Router                                     │
│                                                       │
│  Determine target display (mouse cursor location)     │
│                                                       │
│  1. DisplayServices (Apple/built-in displays)         │
│     └─ if not available ─────────────────────┐        │
│  2. CoreDisplay (Apple fallback)             │        │
│     └─ if not available ─────────────────────┤        │
│  3. DDC/CI VCP 0x10 (external monitors)      │        │
│     ├─ + instant gamma feedback (hybrid)     │        │
│     └─ if not available ─────────────────────┤        │
│  4. Gamma table dimming (universal software) │        │
│     └─ if not available (DisplayLink) ───────┤        │
│  5. Overlay dimming (truly universal)        │        │
│     └─ if all else fails ────────────────────┤        │
│  6. Show "no brightness control" in menu     ◄────────┘
│                                                       │
└──────────────────────────────────────────────────────┘
```

---

## Open Questions & Research Items

### Must Answer Before v1.1
- [ ] Does `CGSetDisplayTransferByFormula` work reliably on macOS 13–15 for the LG HDR 4K? Quick test needed.
- [ ] How does `DisplayServicesGetBrightness(CGMainDisplayID())` behave on Mac Studio when main display is external? (Returns -1? Returns 0? Crashes?)
- [ ] Does gamma table modification interact with the LG's HDR mode? (Could be problematic if monitor is in HDR)
- [ ] What is the performance impact of gamma table updates at 60Hz during fast knob rotation?

### Must Answer Before v1.2
- [ ] **DDC test on LG HDR 4K over HDMI from Mac Studio** — Install MonitorControl or BetterDisplay and test.
- [ ] Does AppleSiliconDDC library support M1 Mac Studio's built-in HDMI port? Or only USB-C/DP?
- [ ] If HDMI DDC fails, does switching to a USB-C → HDMI cable fix it?
- [ ] What is the LG HDR 4K's DDC brightness range? (Some monitors report 0–100, others 0–max where max != 100)
- [ ] Does the LG need DDC/CI enabled in its OSD settings? (Some monitors ship with it off)

### Must Answer Before v1.3
- [ ] Does `window.sharingType = .none` reliably hide the overlay from screenshots on macOS 13–15?
- [ ] Can we detect DisplayLink displays programmatically? (Vendor ID? IOKit service?)
- [ ] Does simultaneous gamma + DDC cause any visual artifacts or conflicts?

### Nice to Research
- [ ] Can `CGVirtualDisplay` (macOS 12+) be used to create a virtual display wrapper with brightness control? (Likely overkill)
- [ ] Is there a way to hook into macOS Accessibility → Reduce White Point programmatically? (It's basically a system-level overlay)
- [ ] Could `CALayer` compositingFilter at the window server level offer a better overlay than `NSWindow`? (Probably not accessible from userspace)
- [ ] Investigate if macOS Tahoe (26) adds any new public APIs for external display brightness (Apple has been slowly improving this)
