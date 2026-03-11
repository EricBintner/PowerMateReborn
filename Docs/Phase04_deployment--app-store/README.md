# Phase 04: Deployment & Distribution

This phase outlines the strategy for distributing PowerMateReborn to end users, transitioning from an open-source hobby project to an easily accessible macOS utility.

## Stage 1: GitHub Releases (.dmg)

The initial distribution method is via direct download of a `.dmg` (Disk Image) file hosted on GitHub Releases. 

### Current Process
- Builds are compiled locally.
- Packaged into a `.dmg` file.
- Uploaded to the [Releases](https://github.com/EricBintner/PowerMateReborn/releases) page of the GitHub repository.

### Requirements for users
- Users download and open the `.dmg`.
- Drag the app to the Applications folder.
- Due to lack of notarization (initially), users may need to bypass Gatekeeper (Right-click > Open).
- The app requires Accessibility permissions to intercept hardware inputs properly.

## Stage 2: Mac App Store (Future Plan)

The long-term goal is to release PowerMateReborn on the Mac App Store to provide a seamless, secure, and auto-updating experience.

### Challenges & Requirements for App Store
1. **Sandboxing:** Mac App Store apps must be strictly sandboxed. We need to ensure that our direct IOKit HID communication and private API usage (like `DisplayServices` for brightness) comply with or can be exempted within App Store guidelines.
2. **Entitlements:** Proper entitlements for USB/HID access must be configured.
3. **Notarization & Signing:** Moving to an Apple Developer account to properly sign and notarize the application.
4. **App Review:** Handling potential rejections if Apple flags the use of private APIs (e.g., CoreDisplay/DisplayServices). If rejected, we may need to rely solely on the `.dmg` distribution or find public API alternatives.
