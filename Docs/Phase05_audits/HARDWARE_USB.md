# Hardware & USB Interaction Audit

## USB Interfacing (`PowerMateHID.swift`)

The application communicates with the Griffin PowerMate (VID `0x077d`, PID `0x0410`) using Apple's `IOKit.hid` framework.

### Connection Management
*   **Matching**: The app correctly uses `IOHIDManagerSetDeviceMatching` to find the specific vendor/product ID combination.
*   **Lifecycle**: Registers callbacks for device matching and removal. It schedules the manager on the main run loop.
*   **Seizing**: The device is opened with `kIOHIDOptionsTypeNone`. According to system-retrieved memories, this works fine on macOS Sequoia, and there is no need to forcefully seize the device (`kIOHIDOptionsTypeSeizeDevice`), which allows other apps (like a generic volume controller) to potentially read from it simultaneously.

### Input Reports (Reading State)
*   **Callback**: Uses `IOHIDDeviceRegisterInputReportCallback` to receive asynchronous updates from the hardware.
*   **Parsing**: The input report is expected to be 6 bytes long.
    *   Byte 0: Button state (Bit 0: 1 = pressed, 0 = released).
    *   Byte 1: Rotation delta (Signed 8-bit integer representing ticks rotated since last report).
*   **Threading**: Input parsing happens on the callback thread, but delegate calls (which update the UI/trigger actions) are correctly dispatched to `DispatchQueue.main.async`.

### Output Reports (Writing State - LED Control)
*   **Method**: Uses `IOHIDDeviceSetReport(..., kIOHIDReportTypeOutput, ...)` sending a single 1-byte payload.
*   **Sequoia Compatibility**: The system-retrieved memories highlight a critical finding: **On macOS Sequoia, the ONLY working write path to control the PowerMate LED is the 1-byte HID output report.**
    *   Legacy methods like Feature `SET_REPORT` or old `IOUSBDeviceInterface` vendor commands either fail with `0xe0005000` or are silently dropped.
*   **Pulsing limitations**: Because only the 1-byte brightness output report works on Sequoia, advanced hardware pulsing/breathing configurations cannot be reliably sent to the device. The `setLEDPulse` function in `PowerMateHID.swift` explicitly notes this limitation and currently just sends a static brightness value, relying on the device's internal state to decide if it should pulse.

### Gesture Detection
*   Gesture logic (single tap, double tap, long press) is implemented entirely in software within `PowerMateHID.swift` using `Timer`s.
*   **Thresholds**:
    *   `longPressThreshold`: 0.5 seconds.
    *   `doubleTapInterval`: 0.3 seconds.
*   **Robustness**: The logic handles cancellation of timers correctly when a new press occurs within an interval. It fires `powerMateButtonReleased` for all raw up-events, allowing clients to handle sustained actions if needed.

## Recommendations & Risks

*   **LED Pulsing Fallback**: Since hardware pulsing isn't configurable on Sequoia, if pulsing is a strong product requirement, consider implementing a *software-driven* pulse. This would involve a fast-firing timer in Swift that repeatedly sends slightly changing brightness values (output reports) to simulate a breathing effect. However, this might spam the USB bus and consume CPU.
*   **Re-enumeration**: If the device gets into a wedged state (e.g., stops sending reports), the memory notes that `USBDeviceReEnumerate` works but destroys the HID layer, requiring a physical replug to fix fully. The app should probably just rely on user replugging rather than trying to programmatically re-enumerate.
*   **Input Report Size Hardcoding**: The code assumes the report buffer is exactly 6 bytes (`let reportSize = 6`). While true for this specific hardware, adding a small sanity check (`if length >= 2`) inside the callback before reading is done, which is good practice.
