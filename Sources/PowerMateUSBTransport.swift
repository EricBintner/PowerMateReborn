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
    private var inputReportBuffer: UnsafeMutablePointer<UInt8>?

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

    /// Send a 1-byte HID output report — the only write path that works on macOS Sequoia.
    /// Must be called on the main thread: the device handle is set/cleared on
    /// the main run loop (IOHIDManager callbacks), and all callers (menu actions,
    /// knob events, LED test below) run on main.
    @discardableResult
    func sendOutputReport(_ value: UInt8) -> Bool {
        assert(Thread.isMainThread, "sendOutputReport called off the main thread")
        guard let hidDevice = device else { return false }
        var report: [UInt8] = [value]
        let result = IOHIDDeviceSetReport(hidDevice, kIOHIDReportTypeOutput, 0, &report, report.count)
        return result == kIOReturnSuccess
    }

    /// Visual startup test: flash LED off->on to confirm communication.
    /// Scheduled on main (no sleeping background thread racing the device
    /// handle on hot-unplug); each step no-ops if the device went away.
    private func runStartupLEDTest() {
        NSLog("LED: startup test — flash off->on")
        sendOutputReport(0)      // LED off
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendOutputReport(255)    // full bright
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.sendOutputReport(0)      // off
        }
        // Restore actual brightness state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
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
        // Free the previous match's buffer and unregister its callback, so
        // hot-plug cycles don't leak a buffer per reconnection.
        inputReportBuffer?.deallocate()
        inputReportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 6)
        IOHIDDeviceRegisterInputReportCallback(hidDevice, inputReportBuffer!, 6, inputCallback, selfPtr)

        // Run startup LED flash test (scheduled on main, non-blocking)
        runStartupLEDTest()

        NSLog("PowerMate device matched")

        DispatchQueue.main.async {
            self.transportDelegate?.transportDidConnect(self)
        }
    }

    private func onDeviceRemoved(_ hidDevice: IOHIDDevice) {
        // Unregister our input callback using the registered buffer (the
        // callback system keeps the pointer; re-registering replaces the
        // callback with a no-op so late reports can't touch our state).
        if let buffer = inputReportBuffer {
            IOHIDDeviceRegisterInputReportCallback(hidDevice, buffer, 6, { _, _, _, _, _, _, _ in }, nil)
        }
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
