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
    // DisplayServices private API (works for Apple/built-in displays).
    // Real C signatures (see MonitorControl/Lunar): the getter writes the
    // brightness through an out-parameter and returns success; the old
    // (UInt32) -> Float reading caused EXC_BAD_ACCESS on built-in displays.
    private typealias GetBrightnessFunc = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Bool
    private typealias SetBrightnessFunc = @convention(c) (UInt32, Float) -> Bool

    private var dsGetBrightness: GetBrightnessFunc?
    private var dsSetBrightness: SetBrightnessFunc?

    // DDC/CI controller (shared, for external monitors)
    let ddcController = DDCController()

    // Per-display state
    class DisplayState {
        var method: BrightnessMethod = .none
        var gammaLevel: Float = 1.0
        var originalGammaRed   = [CGGammaValue](repeating: 0, count: 256)
        var originalGammaGreen = [CGGammaValue](repeating: 0, count: 256)
        var originalGammaBlue  = [CGGammaValue](repeating: 0, count: 256)
        var gammaTableCaptured = false
        var overlayWindow: NSWindow?
        var overlayLevel: Float = 1.0
    }
    
    private var states: [CGDirectDisplayID: DisplayState] = [:]

    // Sync state
    var syncDisplays: Bool = true {
        didSet { UserDefaults.standard.set(syncDisplays, forKey: "powermate.brightness.sync") }
    }

    // Night mode state
    private(set) var nightModeActive: Bool = false
    private var brightnessBeforeNight: Float = 1.0

    // Multi-display: track which display we're actively controlling
    private(set) var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()
    
    var method: BrightnessMethod {
        return states[activeDisplayID]?.method ?? .none
    }

    // Per-display preferences: display serial -> last brightness level
    private var displayPreferences: [String: Float] = [:]

    init() {
        if UserDefaults.standard.object(forKey: "powermate.brightness.sync") != nil {
            syncDisplays = UserDefaults.standard.bool(forKey: "powermate.brightness.sync")
        }
        loadDisplayServices()
        loadDisplayPreferences()
        activeDisplayID = displayUnderMouse()
        probeDisplays()
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

    /// Read brightness via DisplayServices; nil if the API is missing or fails.
    private func dsGet(displayID: CGDirectDisplayID) -> Float? {
        guard let getter = dsGetBrightness else { return nil }
        var value: Float = -1
        let ok = getter(displayID, &value)
        guard ok, value >= 0.0, value <= 1.0 else { return nil }
        return value
    }

    /// Write brightness via DisplayServices; false if the API is missing or fails.
    @discardableResult
    private func dsSet(displayID: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setter = dsSetBrightness else { return false }
        return setter(displayID, value)
    }

    private func probeDisplays(forceRedetect: Bool = false) {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &count)

        var newStates: [CGDirectDisplayID: DisplayState] = [:]

        for i in 0..<Int(count) {
            let displayID = displayIDs[i]
            if let existing = states[displayID], !forceRedetect {
                // Reuse the state (keeps the pristine gamma baseline), but
                // re-check DDC health: sleep/wake breaks IOAVService handles
                // and the user can disable DDC globally, leaving a stale
                // .ddcHardware/.ddcHybrid whose writes silently no-op.
                recheckDDCHealth(existing, for: displayID)
                newStates[displayID] = existing
            } else if let existing = states[displayID] {
                // Forced re-detection (launch, DDC toggle): re-run detection
                // into the existing state so a captured gamma baseline
                // survives instead of being re-captured (possibly dimmed).
                newStates[displayID] = detectMethod(for: displayID, into: existing)
            } else {
                let state = DisplayState()
                newStates[displayID] = detectMethod(for: displayID, into: state)
                // Restore preference if exists
                if let pref = loadDisplayPreference(for: displayID) {
                    NSLog("Brightness: restoring saved level %.0f%% for display %d", pref * 100, displayID)
                    setBrightness(pref, for: displayID)
                }
            }
        }
        
        // Cleanup old states
        for (oldID, state) in states {
            if newStates[oldID] == nil {
                state.overlayWindow?.orderOut(nil)
            }
        }
        
        states = newStates
    }

    /// Detect the brightness method for a display. Pass an existing state to
    /// preserve its captured gamma baseline across re-detections (a fresh
    /// capture while dimmed would corrupt the restore point); the state's
    /// method is updated in place. Gamma tables are only captured when the
    /// existing state has none.
    private func detectMethod(for displayID: CGDirectDisplayID, into state: DisplayState) -> DisplayState {
        // Tier 1: DisplayServices (Apple/built-in displays)
        if dsGetBrightness != nil, dsSetBrightness != nil {
            if let current = dsGet(displayID: displayID) {
                let testVal: Float = (current < 0.5) ? current + 0.02 : current - 0.02
                dsSet(displayID: displayID, testVal)
                usleep(50_000)
                let readback = dsGet(displayID: displayID)
                dsSet(displayID: displayID, current)

                if let readback = readback, abs(readback - testVal) < 0.02 {
                    state.method = .displayServices
                    NSLog("Brightness: display %d using DisplayServices", displayID)
                    return state
                }
            }
        }

        // Tier 2: DDC/CI (external monitors with hardware brightness)
        if ddcController.isEnabled && ddcController.supportsDDC(displayID: displayID) {
            if !state.gammaTableCaptured {
                captureOriginalGamma(for: displayID, into: state)
            }
            if state.gammaTableCaptured {
                state.method = .ddcHybrid
                NSLog("Brightness: display %d using DDC+Gamma hybrid", displayID)
            } else {
                state.method = .ddcHardware
                NSLog("Brightness: display %d using DDC/CI hardware only", displayID)
            }
            return state
        }

        // Tier 3: Gamma table manipulation (any non-DisplayLink display)
        if !state.gammaTableCaptured {
            captureOriginalGamma(for: displayID, into: state)
        }
        if state.gammaTableCaptured {
            state.method = .gamma
            NSLog("Brightness: display %d using Gamma fallback", displayID)
            return state
        }

        // Tier 4: Overlay (truly universal — DisplayLink, AirPlay, etc.)
        state.method = .overlay
        NSLog("Brightness: display %d using Overlay fallback", displayID)
        return state
    }

    private func captureOriginalGamma(for displayID: CGDirectDisplayID, into state: DisplayState) {
        var sampleCount: UInt32 = 0
        let result = CGGetDisplayTransferByTable(
            displayID, 256,
            &state.originalGammaRed, &state.originalGammaGreen, &state.originalGammaBlue,
            &sampleCount)
        state.gammaTableCaptured = (result == .success && sampleCount > 0)
    }

    // MARK: - Public API

    func getCurrentBrightness() -> Float {
        return getCurrentBrightness(for: activeDisplayID)
    }

    func getCurrentBrightness(for displayID: CGDirectDisplayID) -> Float {
        guard let state = states[displayID] else { return 0.5 }
        
        switch state.method {
        case .displayServices:
            return dsGet(displayID: displayID) ?? 0.5
        case .ddcHardware, .ddcHybrid:
            if let ddc = ddcController.getBrightness(displayID: displayID) {
                return Float(ddc) / 100.0
            }
            return state.gammaLevel
        case .gamma:
            return state.gammaLevel
        case .overlay:
            return state.overlayLevel
        case .none:
            return 0.5
        }
    }

    func setBrightness(_ brightness: Float) {
        if syncDisplays {
            let activeCurrent = getCurrentBrightness(for: activeDisplayID)
            let actualDelta = brightness - activeCurrent
            for displayID in states.keys {
                let current = getCurrentBrightness(for: displayID)
                setBrightness(current + actualDelta, for: displayID)
            }
        } else {
            setBrightness(brightness, for: activeDisplayID)
        }
    }

    func setBrightness(_ brightness: Float, for displayID: CGDirectDisplayID) {
        guard let state = states[displayID] else { return }
        let clamped = max(0.0, min(1.0, brightness))

        switch state.method {
        case .displayServices:
            let applied = dsSet(displayID: displayID, clamped)
            if !applied {
                // API rejected the write outright — downgrade right away
                NSLog("Brightness: DisplayServices set failed for %d. Downgrading to Gamma.", displayID)
                captureOriginalGamma(for: displayID, into: state)
                if state.gammaTableCaptured {
                    state.method = .gamma
                    applyGamma(clamped, for: displayID, state: state)
                } else {
                    state.method = .overlay
                    applyOverlay(clamped, for: displayID, state: state)
                }
            } else {
                // Reliability sanity check: if the API silently fails, downgrade to Gamma
                usleep(10_000) // 10ms wait for it to apply
                if let readback = dsGet(displayID: displayID),
                   abs(readback - clamped) > 0.1 && abs(readback - state.gammaLevel) > 0.1 {
                    NSLog("Brightness: DisplayServices silently failed for %d. Downgrading to Gamma.", displayID)
                    captureOriginalGamma(for: displayID, into: state)
                    if state.gammaTableCaptured {
                        state.method = .gamma
                        applyGamma(clamped, for: displayID, state: state)
                    } else {
                        state.method = .overlay
                        applyOverlay(clamped, for: displayID, state: state)
                    }
                } else {
                    state.gammaLevel = clamped // Keep sync for hybrid logic if needed
                }
            }

        case .ddcHybrid:
            state.gammaLevel = clamped
            applyGamma(clamped, for: displayID, state: state)
            let ddcVal = UInt8(clamped * 100)
            ddcController.setBrightness(ddcVal, displayID: displayID)

        case .ddcHardware:
            let ddcVal = UInt8(clamped * 100)
            ddcController.setBrightness(ddcVal, displayID: displayID)

        case .gamma:
            state.gammaLevel = clamped
            applyGamma(clamped, for: displayID, state: state)

        case .overlay:
            state.overlayLevel = clamped
            applyOverlay(clamped, for: displayID, state: state)

        case .none:
            break
        }

        saveDisplayPreference(level: clamped, for: displayID)
    }

    func adjustBrightness(by delta: Float) {
        if syncDisplays {
            for displayID in states.keys {
                let current = getCurrentBrightness(for: displayID)
                setBrightness(current + delta, for: displayID)
            }
        } else {
            let current = getCurrentBrightness(for: activeDisplayID)
            setBrightness(current + delta, for: activeDisplayID)
        }
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

    /// Toggle night mode (deep dim to near-black).
    func toggleNightMode(dimLevel: Float = 0.05) {
        if nightModeActive {
            nightModeActive = false
            setBrightness(brightnessBeforeNight)
            // Clean up all overlays explicitly
            for (id, state) in states {
                removeOverlay(for: id, state: state)
                // restore whatever state says
                setBrightness(getCurrentBrightness(for: id), for: id)
            }
            NSLog("Brightness: night mode OFF, restored to %.0f%%", brightnessBeforeNight * 100)
        } else {
            brightnessBeforeNight = getCurrentBrightness()
            nightModeActive = true
            
            // Apply overlay to all displays (regardless of sync)
            for (id, state) in states {
                applyOverlay(dimLevel, for: id, state: state)
            }
            NSLog("Brightness: night mode ON (%.0f%%)", dimLevel * 100)
        }
    }

    // MARK: - DDC/CI Control

    /// Re-probe displays. Called when the user toggles DDC/CI or after the
    /// user setting is applied at launch — force re-detection so displays
    /// don't sit at a stale method (gamma baselines are preserved).
    func reprobeDisplays(force: Bool = false) {
        ddcController.probeDisplays()
        probeDisplays(forceRedetect: force)
    }

    // MARK: - Cleanup

    /// Restore original gamma on quit.
    ///
    /// On modern macOS (especially Tahoe) CGSetDisplayTransferByTable behaves
    /// inconsistently, so instead of writing the captured table back directly,
    /// ask macOS to restore the profile-defined tables via ColorSync. Overlays
    /// are always removed regardless of method.
    func restoreGamma() {
        var hadGammaState = false
        for (_, state) in states {
            if (state.method == .gamma || state.method == .ddcHybrid) && state.gammaTableCaptured {
                hadGammaState = true
            }
            state.overlayWindow?.orderOut(nil)
        }

        guard hadGammaState else { return }
        CGDisplayRestoreColorSyncSettings()
    }

    /// Update the target display to whichever screen the mouse cursor is on.
    func updateTargetDisplay() {
        let newID = displayUnderMouse()
        guard newID != activeDisplayID else { return }

        // We no longer remove gamma/overlay on switch, since displays run concurrently now!
        activeDisplayID = newID
        NSLog("Brightness: focus switched to display %d (%@)", activeDisplayID, activeDisplayName)
    }

    /// The name of the active display (for UI)
    var activeDisplayName: String {
        return displayName(for: activeDisplayID)
    }
    
    private func displayName(for displayID: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(displayID) != 0 { return "Built-in" }
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        switch vendor {
        case 0x1E6D: return "LG Display"
        case 0x10AC: return "Dell Display"
        case 0x0610: return "Apple Display"
        case 0x0469: return "Samsung Display"
        default: return "Display \(model)"
        }
    }

    // MARK: - Per-Display Preferences

    private func displaySerialKey(for displayID: CGDirectDisplayID) -> String {
        return "\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))"
    }

    private func saveDisplayPreference(level: Float, for displayID: CGDirectDisplayID) {
        let key = displaySerialKey(for: displayID)
        displayPreferences[key] = level
        UserDefaults.standard.set(displayPreferences, forKey: "powermate.brightness.displayPrefs")
    }

    private func loadDisplayPreference(for displayID: CGDirectDisplayID) -> Float? {
        let key = displaySerialKey(for: displayID)
        return displayPreferences[key]
    }

    private func loadDisplayPreferences() {
        // UserDefaults stores values as NSNumber; the old `as? [String: Float]`
        // cast always failed, so saved per-display levels were never restored.
        guard let stored = UserDefaults.standard.dictionary(forKey: "powermate.brightness.displayPrefs") else { return }
        var prefs: [String: Float] = [:]
        for (key, value) in stored {
            if let number = value as? NSNumber {
                prefs[key] = number.floatValue
            }
        }
        displayPreferences = prefs
    }

    // MARK: - Display Change Listeners

    private func installDisplayChangeListeners() {
        CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let self_ = Unmanaged<BrightnessController>.fromOpaque(userInfo).takeUnretainedValue()
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self_.onDisplayReconfigured()
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

    private func onDisplayReconfigured() {
        probeDisplays()

        // Re-apply gamma to all
        for (id, state) in states {
            if (state.method == .gamma || state.method == .ddcHybrid) && state.gammaLevel < 1.0 {
                applyGamma(state.gammaLevel, for: id, state: state)
            }
        }
    }

    private func onSystemWake() {
        // Sleep/wake often breaks IOAVService handles, force a full DDC reprobe
        NSLog("Brightness: System woke from sleep, re-probing displays...")
        ddcController.probeDisplays()
        onDisplayReconfigured()
    }

    /// Re-check a cached DDC method on an attached display. Sleep/wake can
    /// break IOAVService handles and the user can disable DDC globally; in
    /// both cases the cached .ddcHardware/.ddcHybrid method silently
    /// no-ops, so fall back to Gamma instead. DisplayServices state is
    /// left alone (its health check runs on every setBrightness).
    private func recheckDDCHealth(_ state: DisplayState, for displayID: CGDirectDisplayID) {
        guard state.method == .ddcHardware || state.method == .ddcHybrid else { return }
        guard ddcController.isEnabled, ddcController.supportsDDC(displayID: displayID) else {
            NSLog("Brightness: DDC no longer healthy for %d — falling back to Gamma", displayID)
            if !state.gammaTableCaptured {
                captureOriginalGamma(for: displayID, into: state)
            }
            state.method = state.gammaTableCaptured ? .gamma : .overlay
            return
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

    private func applyGamma(_ level: Float, for displayID: CGDirectDisplayID, state: DisplayState) {
        guard state.gammaTableCaptured else { return }
        let factor = max(0.01, level)

        var scaledRed   = [CGGammaValue](repeating: 0, count: 256)
        var scaledGreen = [CGGammaValue](repeating: 0, count: 256)
        var scaledBlue  = [CGGammaValue](repeating: 0, count: 256)

        for i in 0..<256 {
            scaledRed[i]   = state.originalGammaRed[i]   * factor
            scaledGreen[i] = state.originalGammaGreen[i] * factor
            scaledBlue[i]  = state.originalGammaBlue[i]  * factor
        }

        CGSetDisplayTransferByTable(displayID, 256,
                                    scaledRed, scaledGreen, scaledBlue)
    }

    // MARK: - Overlay Implementation

    private func applyOverlay(_ level: Float, for displayID: CGDirectDisplayID, state: DisplayState) {
        let opacity = max(0, min(1, 1.0 - level))

        if opacity < 0.001 {
            removeOverlay(for: displayID, state: state)
            return
        }

        let window = overlayWindow(for: displayID, state: state)
        window.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(opacity))
        window.orderFrontRegardless()
    }

    private func overlayWindow(for displayID: CGDirectDisplayID, state: DisplayState) -> NSWindow {
        if let existing = state.overlayWindow { return existing }

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
        window.sharingType = .none

        state.overlayWindow = window
        return window
    }

    private func removeOverlay(for displayID: CGDirectDisplayID, state: DisplayState) {
        state.overlayWindow?.orderOut(nil)
        state.overlayWindow = nil
    }
}

// MARK: - NSScreen Display ID Extension

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
}
