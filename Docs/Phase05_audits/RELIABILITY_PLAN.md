# Reliability & Fallbacks Implementation Plan

Based on the Audio & Display APIs Audit, the application design is solid but relies on a multi-tiered approach that is fragile if certain edge cases are not handled properly. To make the app as reliable as possible (prioritizing function over App Store approval), we will implement the following items, ordered by risk and impact.

## 1. High Priority (Immediate Risk of Bad UX)

### 1.1. Crash-Proof Gamma Restoration
*   **The Risk**: When using Tier 3 (Gamma Table Manipulation) for brightness, the app alters the system-wide display color lookup table. If the app crashes or is force-quit via Activity Monitor, the `applicationWillTerminate` delegate method is never called, leaving the user's screen permanently dimmed until they reboot or change display settings.
*   **The Fix**: Implement POSIX signal handlers (`SIGINT`, `SIGTERM`) in `main.swift` to catch termination signals before the process dies.
*   **Implementation Steps**:
    1.  Make `AppDelegate` accessible via a static shared instance.
    2.  In `main.swift`, register `signal()` handlers for `SIGINT` and `SIGTERM`.
    3.  In the handler, invoke `AppDelegate.shared.brightnessController.restoreGamma()`.
    4.  *Status: Implemented ✅*

### 1.2. Aggregate Device Filtering
*   **The Risk**: macOS allows users to create "Aggregate Devices" (combining multiple audio interfaces into one). According to `RESEARCH_AUDIO.md`, these are a dead end for direct volume control via CoreAudio. If they appear in the UI, users will select them and be frustrated when the knob does nothing.
*   **The Fix**: Explicitly filter out devices with transport type `kAudioDeviceTransportTypeAggregate` during the CoreAudio discovery phase.
*   **Implementation Steps**:
    1.  Modify `VolumeController.enumerateOutputDevices()`.
    2.  Check `info.transportType != kAudioDeviceTransportTypeAggregate` before appending to the results array.
    3.  *Status: Implemented ✅*

## 2. Medium Priority (Edge Cases & Thread Safety)

### 2.1. "Dead" Virtual Audio Device Fallback
*   **The Risk**: Applications like OBS, Jump Desktop, or BlackHole create virtual audio devices. Sometimes these devices falsely advertise a `VolumeScalar` or AppleScript support, but actually changing the value does nothing to the audio stream.
*   **The Fix**: Ensure the `VolumeController` properly falls back to `softwareVolume` (internal tracking) if a virtual device is selected and native methods fail or are known to be unreliable for that specific transport type.
*   **Implementation Steps**:
    1.  In `VolumeController.refreshAllDevices()`, strengthen the fallback logic. If a device is virtual (`kAudioDeviceTransportTypeVirtual`) and claims `.appleScript` support, force it to `.softwareVolume` instead, as AppleScript rarely works on virtual routing drivers.
    2.  In `VolumeController.setActiveDevice()`, apply the same virtual-device guard when manually switching devices.
    3.  After fallback search in `refreshAllDevices()`, add a final safety check: if the resolved device is still virtual + AppleScript, force to `.softwareVolume`.
    4.  *Status: Implemented ✅*

### 2.2. DDC/CI Async Safety & Sleep/Wake State
*   **The Risk**: DDC/CI uses I2C communication (`IOAVServiceWriteI2C`). This is extremely slow (often taking 40-100ms per command). If the user spins the knob rapidly, it can block the main thread or overwhelm the display's I2C bus, causing it to lock up. Additionally, after sleep/wake, displays often reset their internal state or lose their `IOAVService` handles.
*   **The Fix**: Ensure all DDC writes are strictly coalesced on a background queue (mostly handled in current codebase). Add aggressive re-probing after the system wakes from sleep.
*   **Implementation Steps**:
    1.  Verify `DDCController.setVCPCoalesced` queue behavior. Confirmed: writes are dispatched to `ddcQueue` (a serial `DispatchQueue`), coalesced via `pendingWrites` dictionary, and rate-limited to 100ms per display.
    2.  In `BrightnessController.installDisplayChangeListeners()`, ensure `NSWorkspace.didWakeNotification` triggers a full `ddcController.probeDisplays()` and rebuilds the service handles.
    3.  *Status: Implemented ✅*

## 2.3. USB State Cleanup on Disconnect
*   **The Risk**: When the PowerMate is physically unplugged, `onDeviceRemoved` is called. If the user unplugs the device *while* holding the button down, or if a timer (like `longPressTimer` or `singleTapTimer`) is currently running, those timers could fire after the device is gone, leading to ghost events or accessing nil references.
*   **The Fix**: Explicitly invalidate all gesture timers and reset tap counts in the `onDeviceRemoved` callback.
*   **Implementation Steps**:
    1.  In `PowerMateHID.swift`, inside `onDeviceRemoved`, call `invalidate()` on all timers.
    2.  Reset `lastButtonState`, `longPressFired`, and `tapCount` to their default values.
    3.  *Status: Implemented ✅*

## 2.4. Press-and-Turn Gesture Cancellation
*   **The Risk**: If a user presses down on the knob and simultaneously turns it (often accidentally, or as a distinct gesture in other apps), the `PowerMateHID` class currently tracks the rotation *and* the button press independently. This can lead to a `longPress` or `singleTap` firing unexpectedly when the user releases the button after a rotation, causing unintended mode switches or mute toggles.
*   **The Fix**: Invalidate gesture timers and clear tap counts if significant rotation occurs while the button is held down.
*   **Implementation Steps**:
    1.  In `PowerMateHID.swift`, add a boolean `rotatedWhilePressed`.
    2.  Set it to `true` inside `onInputReport` if rotation != 0 and `buttonDownTime != nil`.
    3.  In `onButtonUp`, if `rotatedWhilePressed` is true, immediately return without triggering single tap or double tap logic.
    4.  *Status: Implemented ✅*

## 2.5. Startup LED Block
*   **The Risk**: The startup LED flash test previously used `usleep` directly in the matching callback thread, blocking it for ~800ms while the device connected.
*   **The Fix**: Move the startup sequence to a background queue (`DispatchQueue.global(qos: .userInitiated)`).
*   **Implementation Steps**:
    1.  Wrap the `usleep` calls in `runStartupLEDTest` inside an async block.
    2.  Ensure it restores `ledBrightness` state after the flash completes.
    3.  *Status: Implemented ✅*

## 2.6. Apple Event Privilege Failures
*   **The Risk**: The app uses `NSAppleScript` to control fallback volume (via "System Events") and to sleep the display. If the user clicks "Don't Allow" on the macOS privacy prompt, or if the system randomly revokes the privilege, these scripts will fail silently or throw opaque errors, leading to a dead knob.
*   **The Fix**: Catch AppleScript execution errors and log them explicitly. For volume control, if AppleScript fails consecutively, downgrade the device's control method to `softwareVolume` automatically.
*   **Implementation Steps**:
    1.  In `VolumeController.swift`, inspect the error returned by `executeAndReturnError`.
    2.  If an error indicates missing privileges (`errAEEventNotHandled` or similar), increment a failure counter.
    3.  If the counter exceeds a threshold, switch `volumeMethod` to `.softwareVolume`.
    4.  *Status: Implemented ✅*

## 3. Low Priority (Polish)

### 3.1. DisplayServices Stability Monitoring
*   **The Risk**: The private `DisplayServices` framework can sometimes silently fail or be changed in minor macOS point updates, returning success but not changing actual brightness.
*   **The Fix**: Add a sanity check. If `DisplayServicesSetBrightness` is called but reading the value back (`DisplayServicesGetBrightness`) immediately after shows no change (beyond a small delta), downgrade that display's method to Gamma or Overlay automatically.
*   **Implementation Steps**:
    1.  In `BrightnessController.swift`, update `setBrightness` under the `.displayServices` case.
    2.  After setting, sleep for 10ms, then read back.
    3.  If the value didn't change (e.g., delta > 0.1), capture gamma and downgrade the state.
    4.  *Status: Implemented ✅*

### 3.2. UI Accessibility (VoiceOver)
*   **The Risk**: Users relying on VoiceOver or other accessibility tools may not be able to navigate the custom SwiftUI settings window or the menu bar items properly.
*   **The Fix**: Add explicit `.accessibilityLabel` and `.accessibilityValue` modifiers to SwiftUI components, and ensure `NSMenuItem` elements have proper accessibility descriptions where necessary.
*   **Implementation Steps**:
    1.  Review `CustomModeSettingsView.swift` and add accessibility modifiers to Buttons, Lists, and Sliders.
    2.  Review `AppDelegate.swift` menu item creation to ensure image-only items or custom views have accessibility labels.
    3.  Add `setAccessibilityLabel()` to the `NSStatusBarButton` so VoiceOver announces the current mode and connection status.
    4.  Add `accessibilityDescription` to `NSImage` icons used in menu items (connection dot, info icon).
    5.  *Status: Implemented ✅*

## 4. Out of Scope (By Design)

### 4.1. App Sandbox & Mac App Store Compliance
*   The application intentionally relies on private frameworks (`DisplayServices`) and unsandboxed hardware access (`IOAVService`, direct `IOKit` HID) to provide a premium, low-latency experience. 
*   It will be distributed via Developer ID / Notarization outside the Mac App Store. Sandbox restrictions and App Store guidelines are not applicable.

---
*This document will be updated as the implementation progresses.*
