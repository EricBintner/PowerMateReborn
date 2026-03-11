# Security & Entitlements Audit

## Current Entitlements
The application currently runs with the following entitlements defined in `PowerMateDriver.entitlements`:

```xml
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.device.audio-input</key>
	<false/>
	<key>com.apple.security.device.audio-output</key>
	<false/>
	<key>com.apple.security.device.bluetooth</key>
	<false/>
	<key>com.apple.security.device.camera</key>
	<false/>
	<key>com.apple.security.device.microphone</key>
	<false/>
	<key>com.apple.security.device.usb</key>
	<false/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<false/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<false/>
</dict>
```

## Analysis

### Sandbox (`com.apple.security.app-sandbox` = `false`)
The application is currently unsandboxed. This is likely necessary for several reasons:
1.  **IOKit/HID Access**: Direct access to USB HID devices via `IOKit` often requires running outside the sandbox, especially for custom vendor commands or when not using standard Apple HID drivers (though standard HID Manager usage sometimes works in sandbox with the `usb` entitlement).
2.  **Private Frameworks**: The application uses the private `DisplayServices.framework` (via `dlopen`) to control Apple display brightness. This is strictly prohibited within the App Sandbox and will lead to App Store rejection.
3.  **DDC/CI Communication**: Communicating with external monitors over I2C/DDC via IOKit also typically requires elevated privileges or an unsandboxed environment.
4.  **AppleScript/System Events**: The app uses `NSAppleScript` to send commands to "System Events" (e.g., to sleep the display). Controlling other applications via AppleScript requires specific entitlements (`com.apple.security.automation.apple-events`) if sandboxed, and often user prompts.

### Device Entitlements
All specific device entitlements (USB, audio, camera, etc.) are set to `false`. Since the app is unsandboxed, these are essentially ignored by the OS. If the app were ever to be sandboxed, it would definitively need `com.apple.security.device.usb` set to `true` to interact with the PowerMate.

### Sparkle Auto-Update
The app integrates `Sparkle` for auto-updates. Sparkle requires the app to have write access to its own bundle to install updates. In a sandboxed environment, this is extremely complex to achieve correctly. Unsandboxed apps can update themselves provided the user running the app has write permissions to the `/Applications` folder (or wherever the app is installed).

## Recommendations & Risks

*   **App Store Distribution**: Given the reliance on private APIs (`DisplayServices`) and the need for unsandboxed execution to perform hardware-level DDC/CI and IOKit HID operations smoothly, **this application cannot be distributed through the Mac App Store**. It must be distributed independently (e.g., via a website with a Developer ID Developer certificate and Notarization).
*   **Notarization**: Apple's Notarization process requires apps to opt-in to the hardened runtime. When enabling the Hardened Runtime, you may need to add specific exceptions to the entitlements file to allow `dlopen` of private frameworks if they cause crashes (e.g., `com.apple.security.cs.disable-library-validation`).
*   **Accessibility Permissions**: Depending on how the application evolves (especially regarding custom modes that might simulate keystrokes or interact with other UI elements), it may need to prompt the user to grant it Accessibility permissions in System Settings -> Privacy & Security.
*   **Apple Events**: The current use of `NSAppleScript` (e.g., in `BrightnessController.swift:272`) will trigger a system prompt asking the user for permission to control "System Events". This needs to be handled gracefully, perhaps with a pre-flight check or a clear onboarding instruction.
