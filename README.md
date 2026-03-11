# PowerMateReborn

![Griffin PowerMate on macOS Sequoia](images/griffin-technology-powermate-mac-os9.png)

A project to resurrect the classic Griffin PowerMate USB for modern Mac setups (Apple Silicon and macOS Sequoia+). 

Since the official drivers haven't worked in years, this is a native Swift menu bar app built from scratch to bring that awesome piece of hardware back to life.

## What It Does

Transform your Griffin PowerMate into a dedicated media control knob for your Mac. Rotate for precise volume and brightness adjustments, press for mute or mode switching, and enjoy smooth LED feedback that matches your system's state.

## Quick Start

- **Rotate:** Adjust volume, brightness, or MIDI CC value.
- **Click:** Snap to preset level (20% vol / 15% brightness). Click again to restore.
- **Double-tap:** Mute audio or sleep display.
- **Long Press:** Cycle modes (Volume / Brightness / MIDI).
- **LED Ring:** Intensity reflects the current level.

## Features

- **Native Swift Driver:** Pure IOKit HID implementation. No legacy kernel extensions or Rosetta required.
- **Menu Bar App:** Lightweight and unobtrusive mode switching.
- **Volume Mode:** Controls all macOS audio devices via CoreAudio with intelligent fallback methods.
- **Brightness Mode:** Adjusts built-in Apple displays and external monitors (gamma fallback, DDC/CI planned).
- **MIDI Mode:** Send MIDI CC messages to any DAW or MIDI-capable app. Knob = CC value, press = note.
- **Hardware Sync:** LED ring brightness tracks the current level in real time.

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

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
