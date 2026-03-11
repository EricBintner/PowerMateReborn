import AppKit
import Foundation
import CoreGraphics

enum BrightnessMethod: String {
    case displayServices = "DisplayServices"
    case gamma = "Gamma"
    case none = "None"

    var isNative: Bool {
        return self == .displayServices
    }
}

class BrightnessController {
    // DisplayServices private API (works for Apple/built-in displays)
    private typealias GetBrightnessFunc = @convention(c) (UInt32) -> Float
    private typealias SetBrightnessFunc = @convention(c) (UInt32, Float) -> Void

    private var dsGetBrightness: GetBrightnessFunc?
    private var dsSetBrightness: SetBrightnessFunc?

    // Gamma fallback state (works for any display including external)
    private var gammaLevel: Float = 1.0
    private var originalGammaRed   = [CGGammaValue](repeating: 0, count: 256)
    private var originalGammaGreen = [CGGammaValue](repeating: 0, count: 256)
    private var originalGammaBlue  = [CGGammaValue](repeating: 0, count: 256)
    private var gammaTableCaptured = false

    private(set) var method: BrightnessMethod = .none

    // Multi-display: track which display we're actively controlling
    private(set) var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()

    init() {
        loadDisplayServices()
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

        // Try DisplayServices first — works for Apple/built-in displays
        if let getter = dsGetBrightness, let setter = dsSetBrightness {
            let current = getter(displayID)
            if current >= 0.0 && current <= 1.0 {
                // Verify it actually works by doing a small test change
                let testVal: Float = (current < 0.5) ? current + 0.02 : current - 0.02
                setter(displayID, testVal)
                usleep(50_000)  // 50ms for hardware to respond
                let readback = getter(displayID)
                setter(displayID, current)  // restore immediately

                if abs(readback - testVal) < 0.02 {
                    method = .displayServices
                    NSLog("Brightness: using DisplayServices (level=%.0f%%)", current * 100)
                    return
                } else {
                    NSLog("Brightness: DisplayServices test failed (set=%.3f read=%.3f) — external display?", testVal, readback)
                }
            }
        }

        // Fall back to gamma table manipulation — works on any display
        captureOriginalGamma()
        if gammaTableCaptured {
            method = .gamma
            NSLog("Brightness: using Gamma fallback (external display)")
        } else {
            method = .none
            NSLog("Brightness: no control method available")
        }
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
        case .gamma:
            return gammaLevel
        case .none:
            return 0.5
        }
    }

    func setBrightness(_ brightness: Float) {
        let clamped = max(0.0, min(1.0, brightness))

        switch method {
        case .displayServices:
            dsSetBrightness?(activeDisplayID, clamped)

        case .gamma:
            gammaLevel = clamped
            applyGamma(clamped)

        case .none:
            break
        }
    }

    func adjustBrightness(by delta: Float) {
        let current = getCurrentBrightness()
        setBrightness(current + delta)
    }

    var isAvailable: Bool {
        return method != .none
    }

    var isVirtual: Bool {
        return method == .gamma
    }

    func sleepDisplay() {
        let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }

    /// Restore original gamma on quit
    func restoreGamma() {
        if method == .gamma && gammaTableCaptured {
            CGSetDisplayTransferByTable(activeDisplayID, 256,
                                        originalGammaRed, originalGammaGreen, originalGammaBlue)
        }
    }

    /// Update the target display to whichever screen the mouse cursor is on.
    /// Call this before adjusting brightness to target the correct monitor.
    func updateTargetDisplay() {
        let newID = displayUnderMouse()
        guard newID != activeDisplayID else { return }

        // Restore gamma on the old display before switching
        if method == .gamma && gammaTableCaptured && gammaLevel < 1.0 {
            CGSetDisplayTransferByTable(activeDisplayID, 256,
                                        originalGammaRed, originalGammaGreen, originalGammaBlue)
        }

        activeDisplayID = newID
        gammaLevel = 1.0
        detectMethod()
        NSLog("Brightness: switched target to display %d", activeDisplayID)
    }

    /// The name of the active display (for UI)
    var activeDisplayName: String {
        if CGDisplayIsBuiltin(activeDisplayID) != 0 { return "Built-in" }
        // Try to get a name from IOKit
        let info = CoreGraphics.CGDisplayCopyDisplayMode(activeDisplayID)
        let vendor = CGDisplayVendorNumber(activeDisplayID)
        let model = CGDisplayModelNumber(activeDisplayID)
        let _ = info // consume unused
        if vendor == 0x1E6D { return "LG Display" }
        if vendor == 0x10AC { return "Dell Display" }
        if vendor == 0x0610 { return "Apple Display" }
        return "Display \(model)"
    }

    // MARK: - Display Change Listeners

    private func installDisplayChangeListeners() {
        // Re-apply gamma after display reconfiguration (sleep/wake, resolution change, display added/removed)
        CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let self_ = Unmanaged<BrightnessController>.fromOpaque(userInfo).takeUnretainedValue()
            // Only act after reconfiguration completes (not before)
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self_.onDisplayReconfigured(displayID)
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        // Also listen for system wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delay for display subsystem to reinitialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.onSystemWake()
            }
        }
    }

    private func onDisplayReconfigured(_ displayID: CGDirectDisplayID) {
        guard method == .gamma else { return }
        // Re-capture original gamma if needed, then re-apply our dimming level
        if gammaLevel < 1.0 {
            NSLog("Brightness: display reconfigured, re-applying gamma (level=%.0f%%)", gammaLevel * 100)
            applyGamma(gammaLevel)
        }
    }

    private func onSystemWake() {
        guard method == .gamma else { return }
        // macOS resets gamma tables on wake — re-capture and re-apply
        captureOriginalGamma()
        if gammaLevel < 1.0 {
            NSLog("Brightness: system wake, re-applying gamma (level=%.0f%%)", gammaLevel * 100)
            applyGamma(gammaLevel)
        }
    }

    // MARK: - Gamma Implementation

    private func displayUnderMouse() -> CGDirectDisplayID {
        let mouseLocation = NSEvent.mouseLocation
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        // Convert from bottom-left (AppKit) to top-left (CG) coordinates
        if let screen = NSScreen.screens.first {
            let cgPoint = CGPoint(x: mouseLocation.x, y: screen.frame.height - mouseLocation.y)
            CGGetDisplaysWithPoint(cgPoint, 16, &displayIDs, &count)
            if count > 0 { return displayIDs[0] }
        }
        return CGMainDisplayID()
    }

    private func applyGamma(_ level: Float) {
        guard gammaTableCaptured else { return }

        // Scale the original gamma table by the brightness level
        // level=1.0 -> full brightness (original), level=0.0 -> black
        // Minimum 0.01 to avoid completely black screen (can't recover)
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
}
