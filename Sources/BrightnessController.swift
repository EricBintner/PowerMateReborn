import Foundation
import CoreGraphics

enum BrightnessMethod: String {
    case displayServices = "DisplayServices"
    case gamma = "Gamma"
    case none = "None"
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

    init() {
        loadDisplayServices()
        detectMethod()
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
        let displayID = CGMainDisplayID()

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
            CGMainDisplayID(), 256,
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
            return dsGetBrightness?(CGMainDisplayID()) ?? 0.5
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
            dsSetBrightness?(CGMainDisplayID(), clamped)

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

    func sleepDisplay() {
        let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }

    /// Restore original gamma on quit
    func restoreGamma() {
        if method == .gamma && gammaTableCaptured {
            CGSetDisplayTransferByTable(CGMainDisplayID(), 256,
                                        originalGammaRed, originalGammaGreen, originalGammaBlue)
        }
    }

    // MARK: - Gamma Implementation

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

        CGSetDisplayTransferByTable(CGMainDisplayID(), 256,
                                    scaledRed, scaledGreen, scaledBlue)
    }
}
