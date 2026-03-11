# PowerMateReborn

![Griffin PowerMate on macOS Sequoia](images/griffin-technology-powermate-mac-os9.png)

A project to resurrect the classic Griffin PowerMate USB for modern Mac setups (Apple Silicon and macOS Sequoia+). 

Since the official drivers haven't worked in years, this is a native Swift menu bar app built from scratch to bring that awesome piece of hardware back to life.

## What It Does

Transform your Griffin PowerMate into a dedicated media control knob for your Mac. Rotate for precise volume and brightness adjustments, press for mute or mode switching, and enjoy smooth LED feedback that matches your system's state.

## Features

- **Native Swift IOKit HID Integration:** Directly reads USB events without relying on legacy drivers or Rosetta.
- **Lightweight Menu Bar App:** Unobtrusive control and mode switching directly from your macOS menu bar.
- **Multi-Mode Support:**
  - 🔊 **Volume Mode:** Smooth rotational volume control with instant mute via button press. Works with all macOS audio devices through intelligent fallback strategies.
  - ☀️ **Brightness Mode:** Precise display brightness adjustment via knob rotation, with button press for keyboard brightness keys. Supports external monitors via planned DDC/CI.
  - ⚙️ **Custom Mode:** (In Development) Programmable actions and macros for future customization.
- **Gesture Recognition:** Supports single press (mute/action), long press (mode cycling), and rotational inputs (with double-tap planned).
- **LED Feedback:** Visual feedback through the PowerMate's LED ring, reflecting current volume or brightness levels.

## Hardware Requirements

- **Device:** Griffin PowerMate USB
- **Identifiers:** Vendor ID `0x077d`, Product ID `0x0410`
- **OS:** macOS Sequoia+ (Optimized for Apple Silicon)

## Installation

This app is currently distributed directly via GitHub Releases.

1. Download the latest `.dmg` release from the [GitHub Releases](https://github.com/EricBintner/PowerMateReborn/releases) page.
2. Open the `.dmg` file.
3. Drag the `PowerMateReborn` app to your Applications folder.
4. Launch the app from your Applications folder.

*Note: You may need to grant Accessibility permissions in System Settings > Privacy & Security > Accessibility for the app to function properly. Since the app is not currently notarized by Apple, you may need to right-click the app and select "Open" the first time you run it.*

## Project Structure & Roadmap

The project is organized into iterative phases (see the `Docs/` folder for deep-dive research):

- **Phase 01:** Initial build and native HID connection setup.
- **Phase 02:** Core app planning, advanced audio volume architecture, and multi-tier brightness research (DDC/CI, DisplayServices).
- **Phase 03:** Custom control implementations and macro support.
- **Phase 04:** Deployment, GitHub Releases, and future Mac App Store distribution plans.

## Research & Documentation

Extensive research has been done on modern macOS limitations and workarounds for hardware control:
- [Audio Control Research](Docs/Phase02_app-planning/RESEARCH_AUDIO.md)
- [Brightness Control Research](Docs/Phase02_app-planning/RESEARCH_BRIGHTNESS.md)

## License

[Add License Information Here]
