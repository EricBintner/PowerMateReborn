import Foundation
import IOKit
import IOKit.hid

// Griffin PowerMate USB identifiers
let kPowerMateVendorID:  Int = 0x077d
let kPowerMateProductID: Int = 0x0410

protocol PowerMateDelegate: AnyObject {
    func powerMateDidConnect()
    func powerMateDidDisconnect()
    func powerMateDidRotate(delta: Int)
    func powerMateButtonPressed()       // single press
    func powerMateButtonDoubleTapped()  // two presses within doubleTapInterval
    func powerMateButtonLongPressed()   // hold >= longPressThreshold
}

class PowerMateHID {
    weak var delegate: PowerMateDelegate?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var lastButtonState: Bool = false

    // Gesture detection
    var longPressThreshold: TimeInterval = 0.5   // seconds
    var doubleTapInterval: TimeInterval = 0.3    // max gap between taps
    private var buttonDownTime: Date?
    private var longPressTimer: Timer?
    private var longPressFired: Bool = false
    private var tapCount: Int = 0
    private var singleTapTimer: Timer?

    // LED state
    private(set) var ledBrightness: UInt8 = 0

    init() {}

    func start() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else { return }

        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: kPowerMateVendorID,
            kIOHIDProductIDKey as String: kPowerMateProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        let matchCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let self_ = Unmanaged<PowerMateHID>.fromOpaque(context).takeUnretainedValue()
            self_.onDeviceMatched(device)
        }

        let removeCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let self_ = Unmanaged<PowerMateHID>.fromOpaque(context).takeUnretainedValue()
            self_.onDeviceRemoved(device)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removeCallback, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        if let manager = manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        device = nil
    }

    var isConnected: Bool {
        return device != nil
    }

    // MARK: - LED Control

    /// Set LED brightness (0-255)
    func setLEDBrightness(_ brightness: UInt8) {
        ledBrightness = brightness
        sendOutputReport(brightness)
    }

    /// Set LED to breathe/pulse
    func setLEDPulse(speed: UInt8, brightness: UInt8 = 255) {
        ledBrightness = brightness
        // On macOS Sequoia, only the 1-byte HID output report reaches the device.
        // We cannot control pulse parameters (feature SET_REPORT is unsupported
        // by this device, and legacy USB vendor commands are dead on Sequoia).
        // Send brightness as output report — the device may or may not pulse
        // depending on its stored firmware state.
        sendOutputReport(brightness)
    }

    // MARK: - LED Implementation

    /// Send a 1-byte HID output report — the only write path that works on macOS Sequoia
    @discardableResult
    private func sendOutputReport(_ value: UInt8) -> Bool {
        guard let hidDevice = device else { return false }
        var report: [UInt8] = [value]
        let result = IOHIDDeviceSetReport(hidDevice, kIOHIDReportTypeOutput, 0, &report, report.count)
        return result == kIOReturnSuccess
    }

    /// Visual startup test: flash LED off->on to confirm communication
    private func runStartupLEDTest() {
        NSLog("LED: startup test — flash off->on")
        sendOutputReport(0)       // LED off
        usleep(300_000)           // 300ms
        sendOutputReport(255)     // LED full bright
        usleep(300_000)           // 300ms
        sendOutputReport(0)       // LED off
        usleep(200_000)           // 200ms
    }

    // MARK: - Private

    private func onDeviceMatched(_ hidDevice: IOHIDDevice) {
        device = hidDevice

        let inputCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
            guard let context = context else { return }
            let self_ = Unmanaged<PowerMateHID>.fromOpaque(context).takeUnretainedValue()
            self_.onInputReport(report: report, length: reportLength)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let reportSize = 6
        let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
        IOHIDDeviceRegisterInputReportCallback(hidDevice, reportBuffer, reportSize, inputCallback, selfPtr)

        // Run startup LED flash test (blocks briefly, runs on callback thread)
        runStartupLEDTest()

        NSLog("PowerMate device matched")

        DispatchQueue.main.async {
            self.delegate?.powerMateDidConnect()
        }
    }

    private func onDeviceRemoved(_ hidDevice: IOHIDDevice) {
        device = nil
        lastButtonState = false
        DispatchQueue.main.async {
            self.delegate?.powerMateDidDisconnect()
        }
    }

    private func onInputReport(report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }

        let buttonByte = report[0]
        let buttonPressed = (buttonByte & 0x01) != 0
        let rotation = Int(Int8(bitPattern: report[1]))

        DispatchQueue.main.async {
            // Button events
            if buttonPressed != self.lastButtonState {
                self.lastButtonState = buttonPressed
                if buttonPressed {
                    self.onButtonDown()
                } else {
                    self.onButtonUp()
                }
            }

            // Rotation events
            if rotation != 0 {
                self.delegate?.powerMateDidRotate(delta: rotation)
            }
        }
    }

    // MARK: - Gesture Detection

    private func onButtonDown() {
        buttonDownTime = Date()
        longPressFired = false

        // Cancel pending single-tap timer (we got another press)
        singleTapTimer?.invalidate()
        singleTapTimer = nil

        // Start long-press timer
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressThreshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.longPressFired = true
            self.tapCount = 0
            self.singleTapTimer?.invalidate()
            self.singleTapTimer = nil
            self.delegate?.powerMateButtonLongPressed()
        }
    }

    private func onButtonUp() {
        longPressTimer?.invalidate()
        longPressTimer = nil

        guard !longPressFired else {
            buttonDownTime = nil
            longPressFired = false
            return
        }

        tapCount += 1

        if tapCount >= 2 {
            // Double tap detected
            tapCount = 0
            singleTapTimer?.invalidate()
            singleTapTimer = nil
            delegate?.powerMateButtonDoubleTapped()
        } else {
            // First tap — wait for possible second tap
            singleTapTimer?.invalidate()
            singleTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapInterval, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.tapCount = 0
                self.delegate?.powerMateButtonPressed()
            }
        }

        buttonDownTime = nil
        longPressFired = false
    }
}
