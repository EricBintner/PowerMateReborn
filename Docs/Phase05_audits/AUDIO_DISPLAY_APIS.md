# Audio & Display APIs Audit

## Audio Control (`VolumeController.swift`)

The application interacts with macOS audio through the `CoreAudio` framework.

### Capabilities & Tiers
According to the research documents and implementation, the app supports several tiers of audio control:
1.  **CoreAudio VolumeScalar (`kAudioDevicePropertyVolumeScalar`)**: The primary and most native way to control volume for devices that support it (e.g., built-in speakers).
2.  **VirtualMasterVolume (`kAudioDevicePropertyVirtualMasterVolume`)**: A crucial fallback for devices that don't have a single master scalar but allow gang-controlling individual channels.
3.  **Mute Control (`kAudioDevicePropertyMute`)**: Used for toggling mute state.
4.  **AppleScript (Fallback)**: Used as a last resort via `set volume output volume X`.

### Implementation Details
*   **Device Discovery**: It queries `kAudioHardwarePropertyDevices` to find all audio hardware and filters for those with output streams.
*   **Listeners**: It installs an `AudioObjectPropertyListenerProc` on the system's default output device (`kAudioHardwarePropertyDefaultOutputDevice`) to react to changes made outside the app (e.g., via the Control Center or physical keyboard).
*   **Thread Safety**: CoreAudio callbacks happen on background threads. The `VolumeController` correctly dispatches delegate updates (`volumeDidChange`) back to the main queue.
*   **Edge Cases**: The code specifically tries to handle devices with unusual names or properties (like stripping " Speakers" from names for UI cleanliness).

### Risks & Missing Pieces
*   **Aggregate Devices**: The research (`RESEARCH_AUDIO.md`) explicitly states Aggregate Devices are not viable for volume control. The code should ideally filter these out from the device picker to prevent user confusion.
*   **"Dead" Virtual Audio Interfaces**: Tools like Jump Desktop or OBS often create virtual audio devices that don't actually respond to volume commands. While `VolumeController` tries to detect `hasVolumeScalar` or `hasVirtualMaster`, the UI fallback might still show them if they expose a fake/unlinked control.

---

## Display Brightness (`BrightnessController.swift`, `DDCController.swift`)

Brightness control is one of the most complex parts of the application, utilizing a multi-tiered approach.

### Tier 1: Native Apple Displays (`DisplayServices`)
*   Uses a private, undocumented framework: `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`.
*   Functions: `DisplayServicesGetBrightness` and `DisplayServicesSetBrightness`.
*   **Risk**: **High App Store rejection risk**. Relying on `dlopen` for private frameworks is strictly prohibited by Apple's review guidelines.

### Tier 2: DDC/CI Hardware Brightness (`DDCController.swift`)
*   Sends I2C commands over the display connection to natively adjust monitor backlights.
*   Uses `IOAVServiceCreate` and `IOAVServiceWriteI2C` / `IOAVServiceReadI2C` (also private/semi-private APIs heavily restricted in recent macOS versions).
*   **Risk**: DDC over certain connections (like HDMI on M1 Macs, as noted in `RESEARCH_BRIGHTNESS.md`) is notoriously unreliable or unsupported by the Apple Silicon display engine. The app needs robust fallbacks if DDC fails silently.

### Tier 3: Gamma Table Manipulation
*   Uses public `CoreGraphics` APIs: `CGGetDisplayTransferByTable` and `CGSetDisplayTransferByTable`.
*   Instead of changing the backlight, it dims the pixel values by altering the color lookup table.
*   **Conflict Risk**: This conflicts with OS features like Night Shift, True Tone, or third-party apps like f.lux. When the app exits or crashes, it must restore the original gamma (`restoreGamma()` in `AppDelegate`), otherwise, the screen might stay permanently dimmed.

### Tier 4: Software Overlay (`OSDOverlay.swift` usage implies, though overlay logic is in `BrightnessController`)
*   Creates a transparent, borderless, floating `NSWindow` overlaying the screen, colored black with varying alpha to simulate dimming.
*   **Drawback**: Does not save power. Can look unnatural as the mouse cursor often renders *above* the overlay, remaining bright white on a dark screen.

### Hybrid Mode
*   The research notes a "hybrid brightness" approach (immediate gamma feedback + queued DDC hardware change). The `detectMethod` in `BrightnessController` returns `.ddcHybrid` if both DDC and Gamma are available, attempting to use Gamma for smooth UI feedback while asynchronously updating the hardware DDC.
