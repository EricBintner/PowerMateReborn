# Architecture Audit
## Overview
The PowerMateDriver is a macOS application written in Swift designed to run in the menu bar. Its primary purpose is to interface with a Griffin PowerMate USB device and provide multi-mode functionality, currently supporting Volume and Brightness control, with stubs for MIDI and Custom modes.

## Core Components
*   **`AppDelegate.swift`**: The central coordinator. Manages the menu bar UI (`NSStatusItem`, `NSMenu`), application lifecycle, user preferences, and routes events from the `PowerMateHID` to the respective controllers (`VolumeController`, `BrightnessController`, `MIDIController`, `CustomModeEngine`).
*   **`PowerMateHID.swift`**: Handles the low-level USB HID communication using `IOKit.hid`. It manages device connection/disconnection, raw input parsing (button presses, rotation), gesture detection (single tap, double tap, long press), and basic LED control via HID output reports.
*   **Controllers (`VolumeController.swift`, `BrightnessController.swift`, etc.)**: Encapsulate the domain logic for their respective modes. They are responsible for querying the system state (e.g., current volume, active display brightness) and applying changes requested by the user via the PowerMate.
*   **`DDCController.swift`**: Manages DDC/CI communication for external monitors, used by `BrightnessController`.

## Structural Analysis
*   **Design Pattern**: The application heavily relies on the Delegate pattern (e.g., `PowerMateDelegate`, `VolumeChangeDelegate`). This provides a clear separation of concerns between event generation (HID layer) and event handling (App layer).
*   **Modularity**: The codebase exhibits good modularity. Controllers are separated by function (Volume vs. Brightness).
*   **State Management**: State is currently distributed. `AppDelegate` holds high-level state (current mode, enabled modes), while individual controllers hold domain-specific state (e.g., `VolumeController` knows the active audio device, `BrightnessController` tracks display methods).

## Potential Improvements
*   **State Centralization**: Consider centralizing application state (e.g., using an observable object or a Redux-like architecture) to make state changes more predictable and easier to debug, especially as more modes (MIDI, Custom) are fleshed out.
*   **Dependency Injection**: The `AppDelegate` directly instantiates its dependencies (`VolumeController`, etc.). Injecting these dependencies would make the classes easier to test in isolation.
*   **Event Routing**: The logic for routing PowerMate events to the active controller is currently hardcoded in `AppDelegate`'s delegate methods (e.g., `powerMateDidRotate`). A more generic routing mechanism (like a responder chain or command pattern) could simplify adding new modes.
