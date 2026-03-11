# UI/UX & Updates Audit

## User Interface (`AppDelegate.swift`, `CustomModeSettingsView.swift`, `OSDOverlay.swift`)

The application is primarily a menu bar utility, with auxiliary windows for settings and visual feedback.

### Menu Bar (`NSStatusItem`)
*   **Iconography**: Uses SF Symbols extensively (e.g., `speaker.wave.2.fill`, `sun.max.fill`). The global rule `no emojis -- use icon fonts or clever graphic design` is strictly followed.
*   **Dynamic Status**: The menu bar icon changes based on the currently active mode and connection status. If disconnected, it shows a specific disconnected icon.
*   **Menu Structure**: The menu is well-organized with sections for Status, Active Mode Selection, Current Controls Status (Volume/Brightness levels), and Settings Submenus (Output Device Picker, Sensitivity, Enabled Modes).
*   **Feedback**: Provides visual cues within the menu, such as a warning icon (`exclamationmark.triangle`) when software dimming is active, educating the user that the backlight is not actually changing.

### On-Screen Display (`OSDOverlay.swift`)
*   **Purpose**: Provides immediate visual feedback (like the native macOS volume/brightness HUDs) when the user turns the knob.
*   **Implementation**: Likely implemented as a floating, transparent `NSWindow` that draws custom graphics. It needs to accurately mimic or blend in with the native macOS aesthetic to feel premium.

### Settings UI (`CustomModeSettingsView.swift`)
*   **Framework**: Built using SwiftUI, which is appropriate for modern macOS preferences windows.
*   **Layout**: Uses a `NavigationSplitView` to separate the profile list (sidebar) from the specific action configurations (detail view).
*   **Features**: Supports per-application profiles and a global fallback profile. Users can add specific applications and map rotation/button actions to them.

## Auto-Updates (`Sparkle`)

The application uses the Sparkle framework for seamless over-the-air updates.

### Integration
*   **Initialization**: Initialized in `AppDelegate` via `SPUStandardUpdaterController`.
*   **Safety Check**: The app intelligently checks if it is running from a `.app` bundle (`Bundle.main.bundleURL.pathExtension == "app"`) before initializing Sparkle. This prevents crashes or errors when running the app directly from Xcode during development (`swift run`).
*   **Appcast**: Relies on an `appcast.xml` file (located in `Docs/appcast.xml` in the repository, though likely deployed to a web server in production) to check for new versions.

### Security Implications
*   As noted in the Security Audit, Sparkle updates for unsandboxed apps require the user to have write permissions to the installation directory. If the app is installed in `/Applications` by an admin but run by a standard user, Sparkle may prompt for admin credentials to perform the update.
*   **EdDSA Signatures**: Modern Sparkle requires updates to be signed with an EdDSA key to ensure payload integrity. This must be part of the release/build pipeline.

## Potential Improvements & Recommendations

*   **Menu Bar Icon Spacing**: Ensure the dynamic menu bar icon doesn't cause surrounding icons to jump when the mode changes. Using fixed-width or custom-drawn `NSImage` representations might be necessary if SF Symbols have varying widths.
*   **OSD Native Feel**: If the custom `OSDOverlay` doesn't exactly match the macOS native HUD (which changed slightly in Monterey and again in Big Sur), it can feel jarring. An alternative is to hook into the system's own OSD notifications, though this relies on undocumented C APIs (`CoreHIServices` or similar) which carry rejection risks.
*   **Accessibility**: Ensure the SwiftUI settings window and the menu bar items have proper VoiceOver labels.
