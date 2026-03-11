import AppKit
import Foundation
import CoreGraphics

enum BrightnessMethod: String {
    case displayServices = "DisplayServices"
    case ddcHardware = "DDC/CI"
    case ddcHybrid = "DDC+Gamma"
    case gamma = "Gamma"
    case overlay = "Overlay"
    case none = "None"

    var isNative: Bool {
        return self == .displayServices || self == .ddcHardware || self == .ddcHybrid
    }

    var isSoftware: Bool {
        return self == .gamma || self == .overlay
    }
}

class BrightnessController {
    // DisplayServices private API (works for Apple/built-in displays)
    private typealias GetBrightnessFunc = @convention(c) (UInt32) -> Float
    private typealias SetBrightnessFunc = @convention(c) (UInt32, Float) -> Void

    private var dsGetBrightness: GetBrightnessFunc?
    private var dsSetBrightness: SetBrightnessFunc?

    // DDC/CI controller (shared, for external monitors)
    let ddcController = DDCController()

    // Gamma fallback state (works for any display including external)
    private var gammaLevel: Float = 1.0
    private var originalGammaRed   = [CGGammaValue](repeating: 0, count: 256)
    private var originalGammaGreen = [CGGammaValue](repeating: 0, count: 256)
    private var originalGammaBlue  = [CGGammaValue](repeating: 0, count: 256)
    private var gammaTableCaptured = false

    // Overlay dimming state
    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var overlayLevel: Float = 1.0

    // Night mode state
    private(set) var nightModeActive: Bool = false
    private var brightnessBeforeNight: Float = 1.0

    private(set) var method: BrightnessMethod = .none

    // Multi-display: track which display we're actively controlling
    private(set) var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    // Per-display preferences: display serial -> last brightness level
    private var displayPreferences: [String: Float] = [:]

    init() {
        loadDisplayServices()
        loadDisplayPreferences()
        activeDisplayID = displayUnderMouse()
        detectMethod()
        installDisplayChangeListeners()
    }

    // MARK: - Setup

    private func loadDisplayServices() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else {
            NSLog("Brightness: DisplayServices.framework not found")
            return
        }
        if let getPtr = dlsym(handle, "DisplayServicesGetBrightness") {
            dsGetBrightness = unsafeBitCast(getPtr, to: GetBrightnessFunc.self)
        }
        if let setPtr = dlsym(handle, "DisplayServicesSetBrightness") {
            dsSetBrightness = unsafeBitCast(setPtr, to: SetBrightnessFunc.self)
        }
    }

    private func detectMethod() {
        let displayID = activeDisplayID

        // Tier 1: DisplayServices (Apple/built-in displays)
        if let getter = dsGetBrightness, let setter = dsSetBrightness {
            let current = getter(displayID)
            if current >= 0.0 && current <= 1.0 {
                let testVal: Float = (current < 0.5) ? current + 0.02 : current - 0.02
                setter(displayID, testVal)
                usleep(50_000)
                let readback = getter(displayID)
                setter(displayID, current)

                if abs(readback - testVal) < 0.02 {
                    method = .displayServices
                    NSLog("Brightness: using DisplayServices (level=%.0f%%)", current * 100)
                    return
                } else {
                    NSLog("Brightness: DisplayServices test failed — external display?")
                }
            }
        }

        // Tier 2: DDC/CI (external monitors with hardware brightness)
        if ddcController.isEnabled && ddcController.supportsDDC(displayID: displayID) {
            // Use hybrid mode: instant gamma feedback + queued DDC hardware change
            captureOriginalGamma()
            if gammaTableCaptured {
                method = .ddcHybrid
                NSLog("Brightness: using DDC+Gamma hybrid (display %d)", displayID)
            } else {
                method = .ddcHardware
                NSLog("Brightness: using DDC/CI hardware only (display %d)", displayID)
            }
            return
        }

        // Tier 3: Gamma table manipulation (any non-DisplayLink display)
        captureOriginalGamma()
        if gammaTableCaptured {
            method = .gamma
            NSLog("Brightness: using Gamma fallback (external display)")
            return
        }

        // Tier 4: Overlay (truly universal — DisplayLink, AirPlay, etc.)
        method = .overlay
        NSLog("Brightness: using Overlay fallback (no gamma support)")
    }

    private func captureOriginalGamma() {
        var sampleCount: UInt32 = 0
        let result = CGGetDisplayTransferByTable(
            activeDisplayID, 256,
            &originalGammaRed, &originalGammaGreen, &originalGammaBlue,
            &sampleCount)
        gammaTableCaptured = (result == .success && sampleCount > 0)
        if gammaTableCaptured {
            NSLog("Brightness: captured gamma table (%d samples)", sampleCount)
        }
    }

    // MARK: - Public API

    func getCurrentBrightness() -> Float {
        switch method {
        case .displayServices:
            return dsGetBrightness?(activeDisplayID) ?? 0.5
        case .ddcHardware, .ddcHybrid:
            if let ddc = ddcController.getBrightness(displayID: activeDisplayID) {
                return Float(ddc) / 100.0
            }
            return gammaLevel  // fall back to gamma tracker
        case .gamma:
            return gammaLevel
        case .overlay:
            return overlayLevel
        case .none:
            return 0.5
        }
    }

    func setBrightness(_ brightness: Float) {
        let clamped = max(0.0, min(1.0, brightness))

        switch method {
        case .displayServices:
            dsSetBrightness?(activeDisplayID, clamped)

        case .ddcHybrid:
            // Instant gamma feedback for smooth knob feel
            gammaLevel = clamped
            applyGamma(clamped)
            // Queued DDC hardware change (rate-limited, catches up in background)
            let ddcVal = UInt8(clamped * 100)
            ddcController.setBrightness(ddcVal, displayID: activeDisplayID)

        case .ddcHardware:
            let ddcVal = UInt8(clamped * 100)
            ddcController.setBrightness(ddcVal, displayID: activeDisplayID)

        case .gamma:
            gammaLevel = clamped
            applyGamma(clamped)

        case .overlay:
            overlayLevel = clamped
            applyOverlay(clamped)

        case .none:
            break
        }

        // Save per-display preference
        saveDisplayPreference(level: clamped)
    }

    func adjustBrightness(by delta: Float) {
        let current = getCurrentBrightness()
        setBrightness(current + delta)
    }

    var isAvailable: Bool {
        return method != .none
    }

    var isVirtual: Bool {
        return method.isSoftware
    }

    func sleepDisplay() {
        let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }

    // MARK: - Night Mode

    /// Toggle night mode (deep dim to near-black). Works with any method.
    func toggleNightMode(dimLevel: Float = 0.05) {
        if nightModeActive {
            // Restore
            nightModeActive = false
            setBrightness(brightnessBeforeNight)
            removeOverlay(for: activeDisplayID)
            NSLog("Brightness: night mode OFF, restored to %.0f%%", brightnessBeforeNight * 100)
        } else {
            // Activate: save current, dim to near-black using overlay
            brightnessBeforeNight = getCurrentBrightness()
            nightModeActive = true
            // Apply overlay on top of whatever method is active
            applyOverlay(dimLevel)
            NSLog("Brightness: night mode ON (%.0f%%)", dimLevel * 100)
        }
    }

    // MARK: - DDC/CI Control

    /// Re-probe DDC displays (call after display connect/disconnect)
    func reprobeDisplays() {
        ddcController.probeDisplays()
        detectMethod()
    }

    // MARK: - Cleanup

    /// Restore original gamma on quit
    func restoreGamma() {
        if (method == .gamma || method == .ddcHybrid) && gammaTableCaptured {
            CGSetDisplayTransferByTable(activeDisplayID, 256,
                                        originalGammaRed, originalGammaGreen, originalGammaBlue)
        }
        // Remove any overlay windows
        for (_, window) in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    /// Update the target display to whichever screen the mouse cursor is on.
    func updateTargetDisplay() {
        let newID = displayUnderMouse()
        guard newID != activeDisplayID else { return }

        // Restore gamma on the old display before switching
        if (method == .gamma || method == .ddcHybrid) && gammaTableCaptured && gammaLevel < 1.0 {
            CGSetDisplayTransferByTable(activeDisplayID, 256,
                                        originalGammaRed, originalGammaGreen, originalGammaBlue)
        }

        // Remove overlay from old display
        removeOverlay(for: activeDisplayID)

        activeDisplayID = newID
        gammaLevel = 1.0
        overlayLevel = 1.0
        detectMethod()

        // Restore saved preference for this display
        if let saved = loadDisplayPreference() {
            gammaLevel = saved
            overlayLevel = saved
        }

        NSLog("Brightness: switched target to display %d (%@)", activeDisplayID, activeDisplayName)
    }

    /// The name of the active display (for UI)
    var activeDisplayName: String {
        if CGDisplayIsBuiltin(activeDisplayID) != 0 { return "Built-in" }
        let vendor = CGDisplayVendorNumber(activeDisplayID)
        let model = CGDisplayModelNumber(activeDisplayID)
        switch vendor {
        case 0x1E6D: return "LG Display"
        case 0x10AC: return "Dell Display"
        case 0x0610: return "Apple Display"
        case 0x0469: return "Samsung Display"
        default: return "Display \(model)"
        }
    }

    // MARK: - Per-Display Preferences

    private func displaySerialKey() -> String {
        return "\(CGDisplayVendorNumber(activeDisplayID))-\(CGDisplayModelNumber(activeDisplayID))-\(CGDisplaySerialNumber(activeDisplayID))"
    }

    private func saveDisplayPreference(level: Float) {
        let key = displaySerialKey()
        displayPreferences[key] = level
        UserDefaults.standard.set(displayPreferences, forKey: "powermate.brightness.displayPrefs")
    }

    private func loadDisplayPreference() -> Float? {
        let key = displaySerialKey()
        return displayPreferences[key]
    }

    private func loadDisplayPreferences() {
        if let prefs = UserDefaults.standard.dictionary(forKey: "powermate.brightness.displayPrefs") as? [String: Float] {
            displayPreferences = prefs
        }
    }

    // MARK: - Display Change Listeners

    private func installDisplayChangeListeners() {
        CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let self_ = Unmanaged<BrightnessController>.fromOpaque(userInfo).takeUnretainedValue()
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self_.onDisplayReconfigured(displayID)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.onSystemWake()
            }
        }
    }

    private func onDisplayReconfigured(_ displayID: CGDirectDisplayID) {
        // Re-probe DDC on display change
        ddcController.probeDisplays()

        if (method == .gamma || method == .ddcHybrid) && gammaLevel < 1.0 {
            NSLog("Brightness: display reconfigured, re-applying gamma (level=%.0f%%)", gammaLevel * 100)
            applyGamma(gammaLevel)
        }
    }

    private func onSystemWake() {
        ddcController.probeDisplays()
        captureOriginalGamma()
        if (method == .gamma || method == .ddcHybrid) && gammaLevel < 1.0 {
            NSLog("Brightness: system wake, re-applying gamma (level=%.0f%%)", gammaLevel * 100)
            applyGamma(gammaLevel)
        }
    }

    // MARK: - Gamma Implementation

    private func displayUnderMouse() -> CGDirectDisplayID {
        let mouseLocation = NSEvent.mouseLocation
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if let screen = NSScreen.screens.first {
            let cgPoint = CGPoint(x: mouseLocation.x, y: screen.frame.height - mouseLocation.y)
            CGGetDisplaysWithPoint(cgPoint, 16, &displayIDs, &count)
            if count > 0 { return displayIDs[0] }
        }
        return CGMainDisplayID()
    }

    private func applyGamma(_ level: Float) {
        guard gammaTableCaptured else { return }
        let factor = max(0.01, level)

        var scaledRed   = [CGGammaValue](repeating: 0, count: 256)
        var scaledGreen = [CGGammaValue](repeating: 0, count: 256)
        var scaledBlue  = [CGGammaValue](repeating: 0, count: 256)

        for i in 0..<256 {
            scaledRed[i]   = originalGammaRed[i]   * factor
            scaledGreen[i] = originalGammaGreen[i] * factor
            scaledBlue[i]  = originalGammaBlue[i]  * factor
        }

        CGSetDisplayTransferByTable(activeDisplayID, 256,
                                    scaledRed, scaledGreen, scaledBlue)
    }

    // MARK: - Overlay Implementation

    private func applyOverlay(_ level: Float) {
        // level 1.0 = no overlay, 0.0 = fully black
        let opacity = max(0, min(1, 1.0 - level))

        if opacity < 0.001 {
            removeOverlay(for: activeDisplayID)
            return
        }

        let window = overlayWindow(for: activeDisplayID)
        window.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(opacity))
        window.orderFrontRegardless()
    }

    private func overlayWindow(for displayID: CGDirectDisplayID) -> NSWindow {
        if let existing = overlayWindows[displayID] { return existing }

        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main!
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.sharingType = .none  // exclude from screenshots/screen recording

        overlayWindows[displayID] = window
        return window
    }

    private func removeOverlay(for displayID: CGDirectDisplayID) {
        overlayWindows[displayID]?.orderOut(nil)
        overlayWindows.removeValue(forKey: displayID)
    }
}

// MARK: - NSScreen Display ID Extension

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
}
