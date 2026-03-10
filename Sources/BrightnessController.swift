import Foundation
import CoreGraphics

class BrightnessController {
    // Use CoreDisplay private API for brightness control
    // These are the same APIs that the brightness keys use internally
    private typealias GetBrightnessFunc = @convention(c) (UInt32) -> Float
    private typealias SetBrightnessFunc = @convention(c) (UInt32, Float) -> Void

    private var getBrightness: GetBrightnessFunc?
    private var setBrightnessFunc: SetBrightnessFunc?
    private var displayServicesLoaded = false

    init() {
        loadDisplayServices()
    }

    private func loadDisplayServices() {
        // Load DisplayServices.framework (private framework)
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            if let getPtr = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightness = unsafeBitCast(getPtr, to: GetBrightnessFunc.self)
            }
            if let setPtr = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightnessFunc = unsafeBitCast(setPtr, to: SetBrightnessFunc.self)
            }
            displayServicesLoaded = (getBrightness != nil && setBrightnessFunc != nil)
            NSLog("DisplayServices loaded: \(displayServicesLoaded)")
        } else {
            NSLog("Failed to load DisplayServices.framework")
        }
    }

    /// Get the main display ID
    private func mainDisplayID() -> UInt32 {
        return CGMainDisplayID()
    }

    /// Get current brightness (0.0 - 1.0)
    func getCurrentBrightness() -> Float {
        if let getBrightness = getBrightness {
            return getBrightness(mainDisplayID())
        }
        return 0.5
    }

    /// Set brightness (0.0 - 1.0)
    func setBrightness(_ brightness: Float) {
        let clamped = max(0.0, min(1.0, brightness))
        if let setBrightnessFunc = setBrightnessFunc {
            setBrightnessFunc(mainDisplayID(), clamped)
        }
    }

    /// Adjust brightness by a delta (-1.0 to 1.0)
    func adjustBrightness(by delta: Float) {
        let current = getCurrentBrightness()
        setBrightness(current + delta)
    }

    /// Whether brightness control is available
    var isAvailable: Bool {
        return displayServicesLoaded
    }

    /// Put display to sleep
    func sleepDisplay() {
        let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }
}
