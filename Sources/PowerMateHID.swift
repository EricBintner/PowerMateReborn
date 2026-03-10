import Foundation
import IOKit
import IOKit.hid

// Griffin PowerMate USB identifiers
let kPowerMateVendorID:  Int = 0x077d
let kPowerMateProductID: Int = 0x0410

// HID Report structure:
//   Input (6 bytes): [button:1bit + pad:7bits] [rotation:int8] [consumer:4bytes]
//   Output (1 byte): LED brightness (0-255)
//   Feature (8 bytes): LED config [brightness, pulse_speed, pulse_style, ...]

protocol PowerMateDelegate: AnyObject {
    func powerMateDidConnect()
    func powerMateDidDisconnect()
    func powerMateDidRotate(delta: Int)
    func powerMateButtonPressed()       // short press (< longPressThreshold)
    func powerMateButtonLongPressed()   // long press (>= longPressThreshold)
}

class PowerMateHID {
    weak var delegate: PowerMateDelegate?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var lastButtonState: Bool = false

    // Long press detection
    var longPressThreshold: TimeInterval = 0.5  // seconds
    private var buttonDownTime: Date?
    private var longPressTimer: Timer?
    private var longPressFired: Bool = false

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
        guard let device = device else { return }
        ledBrightness = brightness

        // Feature report format for static brightness:
        // Byte 0: brightness (0-255)
        // Byte 1: pulse speed (0 = no pulse)
        // Byte 2: pulse style (0 = normal, 1 = solid during pulse, 2 = off during pulse)
        // Byte 3: pulse while asleep (0 = no, 1 = yes)
        // Byte 4: pulse while awake (0 = no, 1 = yes)
        // Bytes 5-7: reserved
        var report: [UInt8] = [brightness, 0, 0, 0, 0, 0, 0, 0]
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &report, report.count)
        if result != kIOReturnSuccess {
            // Fallback: try output report (single byte)
            var outReport: [UInt8] = [brightness]
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &outReport, outReport.count)
        }
    }

    /// Set LED pulse effect
    func setLEDPulse(speed: UInt8, brightness: UInt8 = 255) {
        guard let device = device else { return }
        ledBrightness = brightness

        var report: [UInt8] = [brightness, speed, 0, 0, 1, 0, 0, 0]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &report, report.count)
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

    // MARK: - Long Press Detection

    private func onButtonDown() {
        buttonDownTime = Date()
        longPressFired = false

        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressThreshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.longPressFired = true
            self.delegate?.powerMateButtonLongPressed()
        }
    }

    private func onButtonUp() {
        longPressTimer?.invalidate()
        longPressTimer = nil

        if !longPressFired {
            delegate?.powerMateButtonPressed()
        }

        buttonDownTime = nil
        longPressFired = false
    }
}
