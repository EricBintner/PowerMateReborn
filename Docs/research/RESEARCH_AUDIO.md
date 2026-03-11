# Research: macOS System Volume Control — Comprehensive Strategy Guide

> **Scope:** macOS system-level volume control only. Per-app / custom app control is out of scope (see Phase 03).  
> **Goal:** Industrial-strength volume control that works for *every* macOS audio device a user could possibly have.  
> **Last updated:** March 2026

---

## Table of Contents

1. [The Problem Space](#the-problem-space)
2. [Audio Device Taxonomy](#audio-device-taxonomy)
3. [Control Strategy Matrix](#control-strategy-matrix)
   - Tier 1: CoreAudio Direct Volume
   - Tier 1b: CoreAudio Virtual Master Volume
   - Tier 2: AppleScript System Volume
   - Tier 3: Simulated Media Keys (CGEvent)
   - Tier 4: DDC/CI Monitor Volume
   - Tier 5: HAL Audio Server Plug-In (Proxy Device)
   - Tier 6: Aggregate / Multi-Output Devices
   - Tier 7: DriverKit Audio Extension
4. [Device Detection & Routing Engine](#device-detection--routing-engine)
5. [Edge Cases & Failure Modes](#edge-cases--failure-modes)
6. [Competitive Landscape](#competitive-landscape)
7. [Implementation Plan](#implementation-plan)
8. [Open Questions & Research Items](#open-questions--research-items)

---

## The Problem Space

macOS audio output is deceptively complex. The "system volume" is not a single value — it's a property of the *current default output device*. Different device types have radically different volume control capabilities:

| Scenario | Volume Control? | Why |
|----------|----------------|-----|
| Built-in speakers | ✅ Full | CoreAudio exposes `VolumeScalar` + `Mute` |
| USB audio interface | ✅ Usually | Most expose hardware volume via CoreAudio |
| Bluetooth headphones | ✅ Full | CoreAudio + transport-level volume (A2DP) |
| 3.5mm headphone jack | ✅ Full | Same as built-in, routed via data source |
| HDMI to monitor | ❌ None | macOS treats HDMI audio as digital passthrough — no software volume |
| DisplayPort to monitor | ❌ None | Same as HDMI — digital passthrough |
| Virtual devices (Jump Desktop, Splashtop) | ❌ Usually none | Drivers don't implement volume properties |
| Aggregate devices | ❌ None | macOS disables volume for aggregate/multi-output devices |
| AirPlay speakers | ⚠️ Partial | Volume works but may have latency, limited range |
| Thunderbolt audio | ✅ Usually | Depends on the interface |
| Pro audio interfaces (RME, UA, etc.) | ⚠️ Varies | Some disable OS volume, preferring hardware mixer |

**The core challenge:** PowerMate must provide a smooth, responsive volume knob experience regardless of which device is active — even when macOS itself says "no volume control available."

---

## Audio Device Taxonomy

### Transport Types (CoreAudio constants)

Every audio device has a transport type queryable via `kAudioDevicePropertyTransportType`:

| Constant | Value | Volume Support | Notes |
|----------|-------|---------------|-------|
| `kAudioDeviceTransportTypeBuiltIn` | `bltn` | ✅ Always | Internal speakers, headphone jack |
| `kAudioDeviceTransportTypeUSB` | `usb ` | ✅ Usually | USB DACs, headsets, interfaces |
| `kAudioDeviceTransportTypeBluetooth` | `blue` | ✅ Always | BT headphones, speakers |
| `kAudioDeviceTransportTypeBluetoothLE` | `blea` | ✅ Usually | BLE audio devices |
| `kAudioDeviceTransportTypeHDMI` | `hdmi` | ❌ Never | Digital passthrough |
| `kAudioDeviceTransportTypeDisplayPort` | `dprt` | ❌ Never | Digital passthrough |
| `kAudioDeviceTransportTypeAirPlay` | `airp` | ⚠️ Partial | Works but latency varies |
| `kAudioDeviceTransportTypeAVB` | `eavb` | ⚠️ Varies | Audio Video Bridging (pro) |
| `kAudioDeviceTransportTypeThunderbolt` | `thun` | ⚠️ Varies | Depends on interface |
| `kAudioDeviceTransportTypeVirtual` | `virt` | ❌ Usually not | Software-only devices |
| `kAudioDeviceTransportTypeAggregate` | `grup` | ❌ Never | macOS disables volume |
| `kAudioDeviceTransportTypePCI` | `pci ` | ⚠️ Varies | Internal sound cards |
| `kAudioDeviceTransportTypeFireWire` | `1394` | ⚠️ Varies | Legacy FireWire interfaces |
| `kAudioDeviceTransportTypeUnknown` | `0` | ❓ Check | Must probe at runtime |

### Volume Property Hierarchy

CoreAudio has multiple volume-related properties, checked in this priority order:

1. **`kAudioDevicePropertyVolumeScalar`** (element 0 = master) — Direct hardware volume, float 0.0–1.0
2. **`kAudioDevicePropertyVolumeScalar`** (elements 1, 2 = L/R channels) — Per-channel if no master
3. **`kAudioHardwareServiceDeviceProperty_VirtualMasterVolume`** — Software-computed master. Synthesizes a single volume from multi-channel devices. **Important: This is what the macOS volume slider uses.** Some devices that appear to lack volume DO support this property.
4. **`kAudioDevicePropertyMute`** — Hardware mute toggle (element 0 = master)
5. **`kAudioDevicePropertyVolumeDecibels`** — dB-scale volume (alternative to scalar)

### Device Capability Detection Algorithm

```
For a given AudioDeviceID:
  1. Query kAudioDevicePropertyTransportType → classify device
  2. Check kAudioDevicePropertyVolumeScalar (element 0) → has master volume?
  3. If no: Check elements 1, 2 → has per-channel volume?
  4. If no: Check kAudioHardwareServiceDeviceProperty_VirtualMasterVolume → has virtual master?
  5. Check kAudioDevicePropertyMute (element 0) → has mute?
  6. Check AudioHardwareServiceIsPropertySettable() → is volume actually writable?
  7. Result: { hasVolume, hasMute, volumeType, isSettable, transportType }
```

**Critical insight:** Step 6 is often overlooked. Some devices *report* having volume properties but return errors when you try to *set* them. Always verify settability.

---

## Control Strategy Matrix

### Tier 1: CoreAudio Direct Volume ✅ IMPLEMENTED

**API:** `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData`  
**Property:** `kAudioDevicePropertyVolumeScalar`  
**Scope:** `kAudioDevicePropertyScopeOutput`

**Works for:** Built-in speakers, USB audio, Bluetooth, most headphones

```swift
// Master volume (element 0)
var address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyVolumeScalar,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: 0  // master
)

// Per-channel fallback (elements 1, 2)
// Some devices (e.g., some USB DACs) only expose per-channel
```

- **Precision:** Float32 (0.0–1.0), effectively ~24-bit resolution
- **Latency:** < 1ms, synchronous
- **Reliability:** Rock-solid for supported devices
- **Status:** Implemented, working

**Known issues:**
- Some USB devices report volume but ignore set operations
- Bluetooth volume may have slight delay due to A2DP negotiation
- Some pro audio interfaces (RME, Universal Audio) deliberately disable OS volume control

### Tier 1b: CoreAudio Virtual Master Volume ⚠️ NOT YET IMPLEMENTED

**API:** `AudioHardwareServiceGetPropertyData` / `AudioHardwareServiceSetPropertyData`  
**Property:** `kAudioHardwareServiceDeviceProperty_VirtualMasterVolume`  
**Framework:** AudioToolbox (not CoreAudio)

**This is the property macOS uses for its own volume slider/OSD.** It's a computed virtual master that:
- Synthesizes a single 0.0–1.0 value from multi-channel devices
- Works on some devices where `VolumeScalar` element 0 doesn't exist
- Handles the dB-to-linear mapping that macOS applies for perceptual loudness

```swift
import AudioToolbox

var virtualVolume: Float32 = 0
var size = UInt32(MemoryLayout<Float32>.size)
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMasterVolume,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
)

// NOTE: Must use AudioHardwareServiceGetPropertyData, NOT AudioObjectGetPropertyData
let status = AudioHardwareServiceGetPropertyData(deviceID, &address, 0, nil, &size, &virtualVolume)
```

- **Precision:** Float32 (0.0–1.0)
- **Latency:** < 1ms
- **Coverage:** Broader than raw VolumeScalar — this should be tried BEFORE falling to AppleScript
- **Caveat:** Returns `kAudioHardwareUnknownPropertyError` for HDMI/DP/virtual devices that truly lack volume

**Priority: HIGH — should be Tier 1b in our fallback chain, before AppleScript.**

### Tier 2: AppleScript System Volume ✅ IMPLEMENTED

**API:** `NSAppleScript` → `set volume output volume`  
**Works for:** Any device where macOS's own volume slider works

```applescript
set volume output volume 50          -- 0-100 integer
set volume output muted true
output volume of (get volume settings)  -- returns integer or "missing value"
```

- **Precision:** Integer 0–100 (1% steps)
- **Latency:** 10–50ms (process spawn + Apple Event dispatch)
- **Reliability:** Returns `missing value` for HDMI/DP/virtual devices
- **Status:** Implemented as fallback

**Known issues:**
- Spawning `NSAppleScript` on every knob tick is expensive. If using this path, debounce/throttle.
- `get volume settings` can return `missing value` for `output volume` while `output muted` still works
- Thread safety: `NSAppleScript` must be called from the main thread or a thread with a run loop

**Optimization opportunity:** Replace with direct `AudioHardwareService` calls (Tier 1b) for devices that support it. Reserve AppleScript only as a true last resort.

### Tier 3: Simulated Media Keys (CGEvent) ✅ TESTED

**API:** `NSEvent.otherEvent(with: .systemDefined, ...)` or `CGEvent` + HID post  
**Key codes:** `NX_KEYTYPE_SOUND_UP` (0), `NX_KEYTYPE_SOUND_DOWN` (1), `NX_KEYTYPE_MUTE` (7)

Simulates the physical volume keys on an Apple keyboard. macOS handles the rest.

```swift
func postMediaKey(_ keyType: Int32, down: Bool) {
    let flags: Int = down ? 0xa00 : 0xb00
    let data1 = Int((keyType << 16) | (down ? 0xa00 : 0xb00))
    let event = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: data1,
        data2: -1
    )
    event?.cgEvent?.post(tap: .cghidEventTap)
}
```

- **Precision:** 1/16 steps (6.25% per key event) — **very coarse**
- **Latency:** < 5ms
- **Coverage:** Works for ANY device that macOS volume keys work with
- **OSD:** Automatically shows the native macOS volume HUD
- **Requires:** Accessibility permissions (`kTCCServiceAccessibility`)

**Improvement opportunity:** Rapid-fire key events to simulate finer control. E.g., 4 quick presses = ~25% change. But this is janky and shows 4 OSD flashes.

**Best use:** Last-resort fallback when all other methods fail. Also useful for "match OSD" behavior.

### Tier 4: DDC/CI Monitor Volume 🔬 RESEARCH PHASE

**Protocol:** DDC/CI (Display Data Channel Command Interface) over I²C  
**VCP Code:** `0x62` (Audio Speaker Volume, range 0–100)

DDC/CI sends commands directly to the monitor's firmware to control its built-in volume, brightness, contrast, input source, etc. This is what **MonitorControl**, **Lunar**, and **BetterDisplay** use.

#### Apple Silicon DDC/CI Status

| Mac | HDMI Port | USB-C/TB Port | Notes |
|-----|-----------|--------------|-------|
| M1 (all) | ⚠️ Unreliable | ✅ Works via DP Alt Mode | M1 HDMI has firmware bugs |
| M2 (all) | ⚠️ Improved | ✅ Works | Better than M1 but not perfect |
| M3 (all) | ✅ Works | ✅ Works | Best Apple Silicon DDC support |
| M4 (all) | ✅ Works | ✅ Works | Continued improvement |
| Mac Studio (M1 Max/Ultra) | ⚠️ Unreliable via HDMI | ✅ Works via TB/USB-C | **User's hardware** |
| Mac Studio (M2 Max/Ultra+) | ✅ Usually works | ✅ Works | Improved |

**Critical finding:** The user's Mac Studio with LG HDR 4K over HDMI may have unreliable DDC/CI due to M1-era HDMI controller limitations. USB-C connection would be more reliable.

#### Implementation Approaches

**4a. Direct IOKit I²C (what MonitorControl/Lunar use)**
```swift
// Requires IOKit framework
// 1. Find the IOFramebuffer service for the display
// 2. Open an I²C connection
// 3. Send DDC/CI formatted command
// VCP code 0x62 = volume, value 0-100
```

- **Effort:** High — must handle IOKit service matching, I²C protocol, DDC packet framing, checksums
- **Reference:** [MonitorControl source](https://github.com/MonitorControl/MonitorControl), [Lunar source](https://github.com/alinpanaitiu/Lunar)
- **Gotcha on Apple Silicon:** `IOFramebuffer` became `IOMobileFramebuffer` on M1. Must use the ARM GPU path.

**4b. BetterDisplay's DDC implementation**
BetterDisplay (by @waydabber) claims full DDC support on ALL Apple Silicon Macs including M1 built-in HDMI. It uses a different IOKit service path. Consider studying its approach or linking to it.

**4c. Shell out to `ddcctl` or `m1ddc`**
- [`m1ddc`](https://github.com/waydabber/m1ddc) — CLI tool specifically for Apple Silicon DDC
- Simple: `m1ddc set volume 50 -d 1`
- **Risk:** External dependency, process spawn overhead

**DDC/CI Considerations:**
- **Latency:** 50–200ms per command (I²C is slow)
- **Rate limiting:** Monitors can crash/hang if DDC commands are sent too fast. Must debounce (~100ms minimum between commands).
- **Read-back:** Can read current volume with VCP code 0x62 get. Some monitors are slow to respond (~500ms).
- **Monitor compatibility:** Most LG, Dell, BenQ, ASUS support DDC/CI. Some Samsung, budget monitors don't.
- **No OSD from macOS:** DDC volume changes won't show the macOS volume HUD. We'd need our own OSD.

### Tier 5: HAL Audio Server Plug-In (Proxy Device) 🔬 RESEARCH PHASE

**Concept:** Create a virtual audio device (HAL plug-in) that acts as a proxy. User sets it as default output. It applies software volume and forwards audio to the real device.

This is the approach used by:
- **[Proxy Audio Device](https://github.com/briankendall/proxy-audio-device)** — Open source, exactly this concept
- **[SoundSource](https://rogueamoeba.com/soundsource/)** — Commercial, uses ACE (Audio Capture Engine) HAL plugin
- **[eqMac](https://github.com/bitgapp/eqMac)** — Open source, HAL plugin with EQ + volume
- **[BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic)** — Open source, AudioServerPlugin for per-app volume
- **[SoundMax](https://github.com/snap-sites/SoundMax)** — Open source, includes HDMI software volume slider

#### Architecture

```
┌──────────────────┐     ┌────────────────────┐     ┌──────────────┐
│  Applications    │────▶│  Proxy Audio Device │────▶│  Real Device │
│  (play audio)    │     │  (HAL Plugin)       │     │  (HDMI, etc) │
└──────────────────┘     │                     │     └──────────────┘
                         │  • Software volume  │
                         │  • Mute             │
                         │  • Shows in macOS   │
                         │    volume controls  │
                         └────────────────────┘
```

**How it works:**
1. A `.driver` bundle is installed to `/Library/Audio/Plug-Ins/HAL/`
2. CoreAudio loads it and presents it as a real audio device
3. The plug-in exposes `VolumeScalar` and `Mute` properties (software-implemented)
4. Audio samples are received, gain is applied, then forwarded to the real output device
5. macOS volume slider, keyboard keys, and OSD all work natively

**Pros:**
- ✅ **Universal** — works for ANY output device (HDMI, DP, virtual, anything)
- ✅ **Native integration** — macOS treats it as a normal device with volume
- ✅ **Fine-grained** — float precision, instant response
- ✅ **OSD works** — keyboard volume keys show the native HUD
- ✅ Open-source implementations exist to study/fork

**Cons:**
- ❌ **Requires installation** — driver must be placed in `/Library/Audio/Plug-Ins/HAL/` (needs admin)
- ❌ **Requires coreaudiod restart** — `sudo killall coreaudiod` (macOS ≥14.4) or reboot
- ❌ **Adds audio path complexity** — potential for buffer underruns, latency, glitches
- ❌ **Maintenance burden** — must be tested against every macOS update
- ❌ **Notarization/signing** — HAL plugins should be signed for Gatekeeper
- ❌ **User confusion** — "Proxy Audio Device" appears in Sound settings

**Key references:**
- Apple's `SimpleAudioDriver` example in AudioServerPlugIn SDK
- `AudioServerPlugIn.h` header (defines the plug-in interface: ~20 methods to implement)
- [libASPL](https://github.com/gavv/libASPL) — C++17 library that handles all the boilerplate

**Effort:** Very High (weeks of development) if building from scratch; Medium if forking proxy-audio-device  
**Risk:** Medium — well-traveled path but requires careful engineering  
**macOS compatibility:** Works on all macOS versions ≥ 10.13. No kext needed.

### Tier 6: Aggregate / Multi-Output Devices ⚠️ LIMITED VALUE

**Concept:** Use CoreAudio's `AudioHardwareCreateAggregateDevice` to wrap a volumeless device in an aggregate that adds volume control.

**Reality check:** macOS **disables volume control for aggregate and multi-output devices.** The volume slider grays out, and keyboard volume keys show the "blocked" icon.

This is a dead end for volume control. However, aggregate devices are useful for:
- Routing audio to multiple outputs simultaneously
- Combining input + output from different devices

**Verdict:** ❌ Not viable for our use case.

### Tier 7: DriverKit Audio Extension 🔬 FUTURE

**API:** AudioDriverKit (WWDC 2021)  
**Concept:** Modern replacement for kexts AND HAL plugins. Runs in userspace with DriverKit sandbox.

Apple introduced `AudioDriverKit` in macOS 12 (Monterey) as the future of audio driver development. It provides:
- A CoreAudio HAL plugin that communicates with a DriverKit extension
- Full volume/mute property support
- Modern async I/O model
- Better security (sandbox, entitlements)

**Pros:**
- ✅ Apple's recommended path forward
- ✅ Better security model than raw HAL plugins
- ✅ Runs in userspace (no kext)

**Cons:**
- ❌ Requires macOS 12+ (our target is 13+, so OK)
- ❌ Very new, limited community knowledge
- ❌ Requires Apple Developer Program for distribution (entitlements)
- ❌ More complex than a simple HAL plugin
- ❌ Sparse documentation

**Verdict:** Future option (v3.0+). HAL plugin (Tier 5) is more pragmatic today.

---

## Device Detection & Routing Engine

### Current Implementation (Simplified)
```
1. Get default output device
2. Check if it has VolumeScalar → CoreAudio
3. Else → AppleScript fallback
```

### Proposed Robust Implementation

```
                    ┌─────────────────────────┐
                    │   Device Change Event    │
                    │ (kAudioHardwareProperty  │
                    │  DefaultOutputDevice)    │
                    └────────────┬────────────┘
                                 ▼
                    ┌─────────────────────────┐
                    │   Enumerate All Devices  │
                    │   & Cache Capabilities   │
                    └────────────┬────────────┘
                                 ▼
                    ┌─────────────────────────┐
                    │   Classify Default       │
                    │   Output Device          │
                    └────────────┬────────────┘
                                 ▼
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                   ▼
     ┌────────────────┐ ┌───────────────┐ ┌─────────────────┐
     │ Has CoreAudio   │ │ Has Virtual   │ │ No Volume       │
     │ VolumeScalar    │ │ Master Volume │ │ Control         │
     └───────┬────────┘ └──────┬────────┘ └────────┬────────┘
             ▼                 ▼                    ▼
     ┌────────────────┐ ┌───────────────┐ ┌─────────────────┐
     │ Tier 1: Direct │ │ Tier 1b:      │ │ Choose Fallback │
     │ CoreAudio      │ │ Virtual Master│ │ Strategy...     │
     └────────────────┘ └───────────────┘ └────────┬────────┘
                                                    ▼
                                    ┌───────────────────────────┐
                                    │ Is it HDMI/DP + monitor   │
                                    │ with DDC/CI support?      │
                                    ├───── Yes ─────┬── No ─────┤
                                    ▼               ▼           ▼
                              ┌──────────┐  ┌────────────┐ ┌──────────┐
                              │ Tier 4:  │  │ Tier 5:    │ │ Tier 3:  │
                              │ DDC/CI   │  │ Proxy HAL  │ │ Media    │
                              │ Volume   │  │ (if inst.) │ │ Keys     │
                              └──────────┘  └────────────┘ └──────────┘
```

### Device Change Listener (Critical Missing Feature)

**Must implement:** A CoreAudio property listener for `kAudioHardwarePropertyDefaultOutputDevice`. When the user plugs in headphones, switches Bluetooth, or changes output in System Settings, we must:

1. Detect the change immediately
2. Re-probe the new device's capabilities
3. Switch to the appropriate volume control strategy
4. Update the menu bar UI (show current device name, volume level)

```swift
// Register listener
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject),
    &address,
    DispatchQueue.main
) { _, _ in
    self.refreshDefaultDevice()
    self.updateUI()
}
```

**Additional listeners needed:**
- `kAudioHardwarePropertyDevices` — device added/removed (USB plug/unplug, BT connect/disconnect)
- `kAudioDevicePropertyDeviceIsAlive` — device died (cable pulled, BT out of range)
- `kAudioDevicePropertyVolumeScalar` — external volume change (another app, keyboard keys)
- `kAudioDevicePropertyMute` — external mute change
- `kAudioDevicePropertyDataSource` — headphone jack plugged/unplugged (on MacBooks)

### Smart Device Selection

When the default device has no volume control, offer the user choices:

1. **Auto-redirect:** Scan for the nearest "controllable" device and control that instead
   - Priority: Built-in speakers > USB audio > Bluetooth > AirPlay
   - Show in menu: "Controlling: Mac Studio Speakers (default output: LG HDR 4K has no volume)"
   
2. **Device picker:** Show all output devices in the menu bar dropdown with their capabilities
   - ✅ = full control, ⚠️ = partial, ❌ = no volume
   - Let user pin their preferred device

3. **Remember preference:** Per-device-combo memory
   - "When LG HDR 4K is default → control Mac Studio Speakers"
   - "When AirPods are default → control AirPods directly"

---

## Edge Cases & Failure Modes

### 1. Volume Jumps on Device Switch
**Problem:** User has volume at 80% on speakers. Switches to headphones (which are at 100%). Ears get blasted.  
**Solution:** Read new device volume immediately on switch. Optionally: apply a "safe max" (e.g., 50%) on first use of a new device.

### 2. Device Disappears Mid-Use
**Problem:** Bluetooth headphones go out of range. USB device unplugged. Device goes from "alive" to "dead."  
**Solution:** Listen for `kAudioDevicePropertyDeviceIsAlive`. Fall back to next-best device. Show notification.

### 3. Volume Changes From External Sources
**Problem:** User changes volume via keyboard, Control Center, or another app. PowerMate's internal state is now stale.  
**Solution:** Listen for `kAudioDevicePropertyVolumeScalar` changes on the active device. Sync internal state + LED.

### 4. HDMI Audio with No Fallback
**Problem:** Mac only has an HDMI monitor connected. No built-in speakers (Mac Studio/Mac Pro). No USB audio. No headphones. Volume is impossible.  
**Solution:** Tier 3 (media keys) as absolute last resort. Or: show a prominent "no volume control available" message and suggest connecting speakers/headphones.

### 5. AppleScript Returns `missing value`
**Problem:** For some devices, `output volume of (get volume settings)` returns `missing value` instead of an integer.  
**Solution:** Detect this case. Don't treat `missing value` as 0. Fall through to next tier.

### 6. Multiple Identical Devices
**Problem:** User has two identical USB headsets. CoreAudio assigns different `AudioDeviceID` values but same name.  
**Solution:** Use device UID (`kAudioDevicePropertyDeviceUID`) for identification, not name or ID (which can change between reboots).

### 7. Rapid Knob Rotation Flooding
**Problem:** Fast knob rotation generates many HID reports. Each triggers a volume set. Can overwhelm CoreAudio, AppleScript, or DDC/CI.  
**Solution:** 
- CoreAudio: Coalesce to max ~60 updates/sec (it can handle this)
- AppleScript: Debounce to max ~10/sec (process spawn is expensive)
- DDC/CI: Debounce to max ~5/sec (I²C is slow, monitors can crash)
- Media keys: Debounce to max ~15/sec

### 8. Audio Device with Volume but No Mute
**Problem:** Some devices expose `VolumeScalar` but not `Mute`. Button press tries to toggle mute → fails silently.  
**Solution:** Check for `kAudioDevicePropertyMute` separately. If no hardware mute: simulate by saving volume, setting to 0.0, and restoring on un-mute.

### 9. Per-Channel Volume Asymmetry
**Problem:** Device has L/R channels at different levels (user set balance). Setting element 0 (master) or setting both channels to the same value destroys the user's balance.  
**Solution:** When adjusting volume, read both channels, compute the delta, and apply it to each channel proportionally to preserve the L/R ratio.

### 10. System Integrity Protection (SIP) Restrictions
**Problem:** macOS SIP can block certain IOKit operations, HAL plugin installation, or DDC/CI access.  
**Solution:** All our APIs are userspace and SIP-compatible. HAL plugins don't require SIP disable — they just need admin install to `/Library/Audio/Plug-Ins/HAL/`.

### 11. Sleep/Wake Volume State
**Problem:** After sleep/wake, audio devices may re-enumerate. Bluetooth devices may reconnect with different `AudioDeviceID`. Volume state may be lost.  
**Solution:** Listen for `NSWorkspace.didWakeNotification`. Re-detect devices. Re-apply any saved volume preferences.

### 12. Sandbox and Hardened Runtime
**Problem:** If distributing via Mac App Store, sandbox restrictions prevent: HAL plugin installation, DDC/CI IOKit access, some CoreAudio operations.  
**Solution:** Distribute outside App Store (direct download + notarization). This gives full IOKit, CoreAudio, and filesystem access.

---

## Competitive Landscape

| App | Approach | HDMI Volume | Free | Notes |
|-----|----------|-------------|------|-------|
| **macOS built-in** | CoreAudio | ❌ | ✅ | No volume for HDMI/DP |
| **SoundSource** ($39) | HAL plugin (ACE) | ✅ Software vol | ❌ | Gold standard. Per-app + device volume |
| **eqMac** (free/pro) | HAL plugin | ✅ Software vol | ✅/❌ | EQ + volume. Open source driver |
| **MonitorControl** (free) | DDC/CI | ✅ Hardware vol | ✅ | Open source. Monitor OSD controls |
| **Lunar** ($23) | DDC/CI + Gamma | ✅ Hardware vol | ❌ | Best DDC/CI on Apple Silicon |
| **BetterDisplay** ($18) | DDC/CI | ✅ Hardware vol | ❌ | Claims M1 HDMI DDC works |
| **BackgroundMusic** (free) | AudioServerPlugin | ⚠️ Limited | ✅ | Per-app volume. Maintenance issues |
| **Proxy Audio Device** (free) | HAL plugin | ✅ Software vol | ✅ | Simple, open source, works well |
| **Sound Control** ($15) | HAL plugin | ✅ Software vol | ❌ | Per-app + device EQ |
| **SoundMax** (free) | HAL plugin | ✅ Software vol | ✅ | Open source. EQ + HDMI volume |

**Our differentiator:** We're not building a general audio tool. We're building a hardware knob experience. The focus is on *responsiveness*, *reliability*, and *zero-config*. The volume control engine is a means to an end — making the PowerMate knob "just work."

---

## Implementation Plan

### Phase A: Harden Existing (v1.1) — Estimated: 1–2 weeks

| # | Task | Priority | Effort | Deps |
|---|------|----------|--------|------|
| A1 | **Add VirtualMasterVolume (Tier 1b)** — Try `kAudioHardwareServiceDeviceProperty_VirtualMasterVolume` before falling to AppleScript. Broader device coverage, same speed as CoreAudio. | 🔴 High | Small | None |
| A2 | **Device change listener** — Register `AudioObjectAddPropertyListenerBlock` for default device changes. Auto-refresh on switch. | 🔴 High | Small | None |
| A3 | **Volume change listener** — Detect external volume changes (keyboard, Control Center). Sync internal state + LED brightness. | 🔴 High | Small | A2 |
| A4 | **Device capability probing** — On startup and device change, enumerate ALL output devices. Cache transport type, volume support, mute support for each. | 🔴 High | Medium | A2 |
| A5 | **Mute simulation** — For devices without `kAudioDevicePropertyMute`: save volume → set 0.0 → restore. | 🟡 Medium | Small | A1 |
| A6 | **L/R balance preservation** — When adjusting volume, detect and preserve channel balance ratio. | 🟡 Medium | Small | A1 |
| A7 | **Rate limiting / debounce** — Per-tier max update rates. Coalesce rapid knob ticks. | 🟡 Medium | Small | None |
| A8 | **Sleep/wake handling** — Re-detect devices on wake. Re-apply volume state. | 🟡 Medium | Small | A2 |
| A9 | **Device picker menu** — Show all output devices in menu bar with capability indicators. Allow user to select which device PowerMate controls. | 🟡 Medium | Medium | A4 |
| A10 | **Settability check** — Call `AudioHardwareServiceIsPropertySettable()` before attempting to set volume. Graceful fallback if not settable. | 🟡 Medium | Small | A1 |

### Phase B: Smart Fallbacks (v1.2) — Estimated: 2–3 weeks

| # | Task | Priority | Effort | Deps |
|---|------|----------|--------|------|
| B1 | **Smart device redirect** — When default device has no volume, auto-select best controllable device. Show in menu. | 🔴 High | Medium | A4 |
| B2 | **Device preference memory** — Remember per-device-combo routing (UserDefaults). "When X is default → control Y." | 🟡 Medium | Small | B1 |
| B3 | **DDC/CI volume (Tier 4)** — Implement DDC/CI volume for HDMI/DP monitors. Start with `m1ddc` CLI, then native IOKit. | 🟡 Medium | High | A4 |
| B4 | **DDC/CI rate limiting** — Max 5–10 commands/sec. Queue + coalesce for fast knob rotation. | 🟡 Medium | Small | B3 |
| B5 | **DDC/CI monitor detection** — Probe which monitors support DDC/CI at startup. Cache results. | 🟡 Medium | Medium | B3 |
| B6 | **Custom OSD overlay** — For DDC/CI and other non-standard paths, show a native-looking volume HUD. | 🟡 Medium | Medium | B3 |
| B7 | **Volume safe max** — On first connection to a new device, cap volume at 50% to prevent ear damage. | 🟢 Low | Small | A4 |

### Phase C: Universal Volume (v2.0) — Estimated: 4–6 weeks

| # | Task | Priority | Effort | Deps |
|---|------|----------|--------|------|
| C1 | **Evaluate proxy audio approach** — Build or fork proxy-audio-device HAL plugin for universal software volume. | 🟡 Medium | Very High | None |
| C2 | **Bundled HAL plugin installer** — If pursuing Tier 5: create a clean install/uninstall flow. Admin prompt, coreaudiod restart. | 🟡 Medium | High | C1 |
| C3 | **Auto-activate proxy** — When default device has no volume AND no DDC/CI, offer to enable proxy device. | 🟡 Medium | Medium | C1, C2 |
| C4 | **DriverKit evaluation** — Research AudioDriverKit as future replacement for HAL plugin. Prototype. | 🟢 Low | High | None |

### Fallback Chain (Final Architecture)

```
PowerMate knob rotation
  │
  ▼
┌──────────────────────────────────────────────────────┐
│ Volume Router                                        │
│                                                      │
│  1. CoreAudio VolumeScalar (master or per-channel)   │
│     └─ if not available ─────────────────────┐       │
│  2. CoreAudio VirtualMasterVolume            │       │
│     └─ if not available ─────────────────────┤       │
│  3. DDC/CI Monitor Volume (if HDMI/DP)       │       │
│     └─ if not available ─────────────────────┤       │
│  4. Proxy Audio Device (if installed)        │       │
│     └─ if not available ─────────────────────┤       │
│  5. AppleScript system volume                │       │
│     └─ if returns missing value ─────────────┤       │
│  6. Simulated media keys (last resort)       │       │
│     └─ if all else fails ────────────────────┤       │
│  7. Show "no volume control" in menu         ◄───────┘
│                                                      │
└──────────────────────────────────────────────────────┘
```

---

## Open Questions & Research Items

### Must Answer Before v1.1
- [ ] Does `kAudioHardwareServiceDeviceProperty_VirtualMasterVolume` work on Mac Studio Speakers? On Jump Desktop Audio? Test all devices.
- [ ] What is the actual update rate CoreAudio can sustain for `VolumeScalar` sets? (likely >100/sec but verify)
- [ ] Does `AudioObjectAddPropertyListenerBlock` fire reliably on macOS 13–15 for all device change scenarios?
- [ ] When Mac Studio Speakers are set as default, does CoreAudio volume work even when speakers are "off" (volume 0)?

### Must Answer Before v1.2
- [ ] Does the user's LG HDR 4K support DDC/CI over HDMI from Mac Studio? Run: `brew install ddcctl && ddcctl -d 1 -v` or test with MonitorControl.
- [ ] What is the minimum DDC/CI command interval for the LG monitor before it crashes/hangs?
- [ ] Can we detect DDC/CI support programmatically without user intervention?
- [ ] Is `m1ddc` reliable enough for production use, or must we implement native IOKit DDC?

### Must Answer Before v2.0
- [ ] Is the proxy-audio-device project actively maintained? Last commit date? macOS 15 compatibility?
- [ ] What is the audio latency introduced by a HAL proxy plugin? (acceptable threshold: <10ms)
- [ ] Can we bundle a HAL plugin inside our .app and install it on first launch with admin prompt?
- [ ] Does notarization work for HAL plugins? (yes, but needs specific entitlements)

### Nice to Research
- [ ] Can `ScreenCaptureKit` (macOS 12.3+) be used to intercept and modify system audio levels? (Likely no — it's for capture, not modification)
- [ ] Is there an undocumented CoreAudio property for system-wide software gain? (Likely no — Apple deliberately avoids this for HDMI/DP)
- [ ] Could we use `AudioUnitSetProperty` on the default output's HAL AU to inject gain? (Unlikely — output AUs are owned by CoreAudio)
- [ ] Investigate `kAudioDevicePropertyPlayThruVolumeScalar` — is this relevant for any pass-through scenario?
