import Foundation
import IOKit
import IOKit.hid

// Griffin PowerMate USB identifiers
let kPowerMateVendorID:  Int = 0x077d
let kPowerMateProductID: Int = 0x0410

/// USB HID transport for the Griffin PowerMate.
/// Reports raw hardware events (rotation, button state) to the PowerMateManager
/// via the PowerMateTransportDelegate protocol. No gesture detection here.
class PowerMateUSBTransport: PowerMateTransport {
    weak var transportDelegate: PowerMateTransportDelegate?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var lastButtonState: Bool = false

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
            let self_ = Unmanaged<PowerMateUSBTransport>.fromOpaque(context).takeUnretainedValue()
            self_.onDeviceMatched(device)
        }

        let removeCallback: IOHIDDeviceCallback = { context, result, sender, device in
            guard let context = context else { return }
            let self_ = Unmanaged<PowerMateUSBTransport>.fromOpaque(context).takeUnretainedValue()
            self_.onDeviceRemoved(device)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removeCallback, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        if let manager = manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
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

    // MARK: - LED Implementation

    /// Send a 1-byte HID output report — the only write path that works on macOS Sequoia
    @discardableResult
    func sendOutputReport(_ value: UInt8) -> Bool {
        guard let hidDevice = device else { return false }
        var report: [UInt8] = [value]
        let result = IOHIDDeviceSetReport(hidDevice, kIOHIDReportTypeOutput, 0, &report, report.count)
        return result == kIOReturnSuccess
    }

    /// Visual startup test: flash LED off->on to confirm communication
    private func runStartupLEDTest() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            NSLog("LED: startup test — flash off->on")
            self.sendOutputReport(0)       // LED off
            usleep(300_000)                // 300ms
            self.sendOutputReport(255)     // LED full bright
            usleep(300_000)                // 300ms
            self.sendOutputReport(0)       // LED off
            usleep(200_000)                // 200ms
            
            // Restore actual brightness state
            self.sendOutputReport(self.ledBrightness)
        }
    }

    // MARK: - Private

    private func onDeviceMatched(_ hidDevice: IOHIDDevice) {
        device = hidDevice

        let inputCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
            guard let context = context else { return }
            let self_ = Unmanaged<PowerMateUSBTransport>.fromOpaque(context).takeUnretainedValue()
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
            self.transportDelegate?.transportDidConnect(self)
        }
    }

    private func onDeviceRemoved(_ hidDevice: IOHIDDevice) {
        device = nil
        lastButtonState = false
        
        DispatchQueue.main.async {
            self.transportDelegate?.transportDidDisconnect(self)
        }
    }

    private func onInputReport(report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }

        let buttonByte = report[0]
        let buttonPressed = (buttonByte & 0x01) != 0
        let rotation = Int(Int8(bitPattern: report[1]))

        DispatchQueue.main.async {
            // Button state change -> report raw event to manager
            if buttonPressed != self.lastButtonState {
                self.lastButtonState = buttonPressed
                self.transportDelegate?.transport(self, buttonStateChanged: buttonPressed)
            }

            // Rotation -> report raw delta to manager
            if rotation != 0 {
                self.transportDelegate?.transport(self, didRotate: rotation)
            }
        }
    }
}
