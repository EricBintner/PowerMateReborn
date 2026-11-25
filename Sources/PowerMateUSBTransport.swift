import Foundation
import IOKit
import IOKit.hid

// Griffin PowerMate USB identifiers
let kPowerMateVendorID:  Int = 0x077d
let kPowerMateProductID: Int = 0x0410

/// USB HID transport for the Griffin PowerMate.
/// One manager can see several knobs. The hardware has no serial number, so
/// each knob is identified by the USB hub it is plugged into (or by the Mac
/// port, when the parent hub has no serial).
class PowerMateUSBTransport: PowerMateTransport {
    weak var transportDelegate: PowerMateTransportDelegate?

    private var manager: IOHIDManager?
    private var openOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
    private var sessions: [USBSession] = []

    private final class USBSession {
        let device: IOHIDDevice
        let locationID: UInt32
        let identity: String
        let displayName: String
        var ledBrightness: UInt8 = 0
        var lastButtonState: Bool = false
        let buffer: UnsafeMutablePointer<UInt8>
        var box: USBCallbackBox?

        init(device: IOHIDDevice, locationID: UInt32, identity: String, displayName: String) {
            self.device = device
            self.locationID = locationID
            self.identity = identity
            self.displayName = displayName
            self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 6)
        }

        deinit {
            buffer.deallocate()
        }
    }

    /// Callback context. Holds the transport weakly so a late report after
    /// removal cannot touch a freed session.
    private final class USBCallbackBox {
        weak var transport: PowerMateUSBTransport?
        let locationID: UInt32
        init(transport: PowerMateUSBTransport, locationID: UInt32) {
            self.transport = transport
            self.locationID = locationID
        }
    }

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

        // Seize the knob. Its descriptor declares the LED echo bytes as a
        // Consumer Control usage, so macOS reads a lit LED as a held media
        // key and auto-repeats it, keeping the displays from idle-sleeping.
        // Seizing keeps macOS from interpreting the reports; we still get them.
        openOptions = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        let result = IOHIDManagerOpen(manager, openOptions)
        // This opens the manager, not a knob: it succeeds with nothing
        // plugged in. A knob is reported when it is matched (onDeviceMatched).
        if result == kIOReturnSuccess {
            NSLog("USB: watching for a PowerMate (exclusive access)")
        } else {
            NSLog("USB: exclusive access failed (0x%08x), watching with shared access — the knob may keep displays awake", result)
            IOHIDManagerClose(manager, openOptions)
            openOptions = IOOptionBits(kIOHIDOptionsTypeNone)
            IOHIDManagerOpen(manager, openOptions)
        }
    }

    func stop() {
        for session in sessions {
            silence(session)
        }
        sessions.removeAll()
        if let manager = manager {
            IOHIDManagerClose(manager, openOptions)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        manager = nil
    }

    var isConnected: Bool {
        return !sessions.isEmpty
    }

    var connectedDevices: [(identity: String, displayName: String)] {
        var seen = Set<String>()
        var result: [(identity: String, displayName: String)] = []
        for session in sessions where seen.insert(session.identity).inserted {
            result.append((session.identity, session.displayName))
        }
        return result
    }

    func owns(_ identity: String) -> Bool {
        sessions.contains { $0.identity == identity }
    }

    func ledBrightness(for identity: String) -> UInt8 {
        sessions.first { $0.identity == identity }?.ledBrightness ?? 0
    }

    func setLEDBrightness(_ brightness: UInt8, identity: String) {
        for session in sessions where session.identity == identity {
            session.ledBrightness = brightness
            sendOutputReport(brightness, to: session)
        }
    }

    // MARK: - LED Implementation

    /// Send a 1-byte HID output report — the only write path that works on macOS Sequoia.
    /// Must be called on the main thread: the device handle is set/cleared on
    /// the main run loop (IOHIDManager callbacks).
    @discardableResult
    private func sendOutputReport(_ value: UInt8, to session: USBSession) -> Bool {
        assert(Thread.isMainThread, "sendOutputReport called off the main thread")
        var report: [UInt8] = [value]
        let result = IOHIDDeviceSetReport(session.device, kIOHIDReportTypeOutput, 0, &report, report.count)
        return result == kIOReturnSuccess
    }

    /// Visual startup test: flash LED off->on to confirm communication.
    /// Scheduled on main (no sleeping background thread racing the device
    /// handle on hot-unplug); each step no-ops if the device went away.
    private func runStartupLEDTest(locationID: UInt32) {
        NSLog("LED: startup test — flash off->on")
        if let session = sessions.first(where: { $0.locationID == locationID }) {
            sendOutputReport(0, to: session)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let session = self?.sessions.first(where: { $0.locationID == locationID }) else { return }
            self?.sendOutputReport(255, to: session)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let session = self?.sessions.first(where: { $0.locationID == locationID }) else { return }
            self?.sendOutputReport(0, to: session)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let session = self?.sessions.first(where: { $0.locationID == locationID }) else { return }
            self?.sendOutputReport(session.ledBrightness, to: session)
        }
    }

    // MARK: - Match / remove

    private func onDeviceMatched(_ hidDevice: IOHIDDevice) {
        let locationID = (IOHIDDeviceGetProperty(hidDevice, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value ?? 0
        if sessions.contains(where: { $0.device === hidDevice }) { return }

        let resolved = resolveIdentity(device: hidDevice, locationID: locationID)
        let session = USBSession(device: hidDevice, locationID: locationID, identity: resolved.identity, displayName: resolved.displayName)
        let box = USBCallbackBox(transport: self, locationID: locationID)
        session.box = box
        sessions.append(session)

        let inputCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
            guard let context = context else { return }
            let box = Unmanaged<USBCallbackBox>.fromOpaque(context).takeUnretainedValue()
            box.transport?.onInputReport(locationID: box.locationID, report: report, length: reportLength)
        }
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(hidDevice, session.buffer, 6, inputCallback, boxPtr)

        NSLog("USB: PowerMate connected %@ (%@) location=0x%08x", session.displayName, session.identity, locationID)
        runStartupLEDTest(locationID: locationID)

        let identity = session.identity
        let displayName = session.displayName
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.transportDelegate?.transportDidConnect(self, identity: identity, displayName: displayName)
        }
    }

    private func onDeviceRemoved(_ hidDevice: IOHIDDevice) {
        guard let index = sessions.firstIndex(where: { $0.device === hidDevice }) else { return }
        let session = sessions[index]
        silence(session)
        sessions.remove(at: index)
        let identity = session.identity
        let stillPresent = sessions.contains { $0.identity == identity }
        NSLog("USB: PowerMate disconnected %@", identity)
        if !stillPresent {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.transportDelegate?.transportDidDisconnect(self, identity: identity)
            }
        }
    }

    private func silence(_ session: USBSession) {
        IOHIDDeviceRegisterInputReportCallback(session.device, session.buffer, 6, { _, _, _, _, _, _, _ in }, nil)
        session.box?.transport = nil
    }

    private func onInputReport(locationID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 2, let session = sessions.first(where: { $0.locationID == locationID }) else { return }

        let buttonByte = report[0]
        let buttonPressed = (buttonByte & 0x01) != 0
        let rotation = Int(Int8(bitPattern: report[1]))
        let identity = session.identity

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let session = self.sessions.first(where: { $0.locationID == locationID }) else { return }
            if buttonPressed != session.lastButtonState {
                session.lastButtonState = buttonPressed
                self.transportDelegate?.transport(self, identity: identity, buttonStateChanged: buttonPressed)
            }
            if rotation != 0 {
                self.transportDelegate?.transport(self, identity: identity, didRotate: rotation)
            }
        }
    }

    // MARK: - Hub identity

    /// The knob's iSerialNumber is 0. The parent hub's USB serial stays put
    /// when that hub moves to another Mac port; locationID does not.
    /// Hubs without a serial (many monitor and dock hubs) still carry a
    /// container ID, which macOS keeps when the hub is replugged or moved to
    /// another port and shares between the hub's USB 2.0 and 3.0 sides.
    private func resolveIdentity(device: IOHIDDevice, locationID: UInt32) -> (identity: String, displayName: String) {
        let nodes = usbAncestors(of: device)
        var parentHub: USBNode?
        // Nodes run from the HID object up to the root. The knob can show up
        // as more than one node (interface and USB device), so take the
        // topmost one; the node after it is the hub it is plugged into.
        if let knobIndex = nodes.lastIndex(where: {
            $0.name.localizedCaseInsensitiveContains("PowerMate") || ($0.location == locationID && locationID != 0)
        }), nodes.count > knobIndex + 1 {
            parentHub = nodes[knobIndex + 1]
            if let hub = parentHub, !hub.serial.isEmpty {
                return ("usb-hub:\(hub.serial)", hubDisplayName(product: hub.name, serial: hub.serial))
            }
        }
        if let hub = nodes.first(where: { !$0.serial.isEmpty && !$0.name.localizedCaseInsensitiveContains("PowerMate") }) {
            return ("usb-hub:\(hub.serial)", hubDisplayName(product: hub.name, serial: hub.serial))
        }
        if let hub = parentHub, !hub.container.isEmpty {
            let tag = String(hub.container.suffix(4))
            let label = hub.name.isEmpty ? "USB PowerMate · \(tag)" : "PowerMate · \(hub.name) · \(tag)"
            return ("usb-container:\(hub.container)", label)
        }
        return ("usb-port:\(locationID)", "USB PowerMate")
    }

    private func hubDisplayName(product: String, serial: String) -> String {
        if !product.isEmpty && !product.localizedCaseInsensitiveContains("PowerMate") {
            return "PowerMate · \(product)"
        }
        let suffix = serial.count > 4 ? String(serial.suffix(4)) : serial
        return "USB PowerMate · \(suffix)"
    }

    private struct USBNode {
        var name: String
        var serial: String
        var container: String
        var location: UInt32
    }

    /// USB device nodes from the HID object up to the root. The PowerMate is
    /// followed by its parent hub.
    private func usbAncestors(of device: IOHIDDevice) -> [USBNode] {
        let service = IOHIDDeviceGetService(device)
        guard service != MACH_PORT_NULL else { return [] }

        var nodes: [USBNode] = []
        var entry = service
        var owned: io_registry_entry_t = 0
        while true {
            if let node = usbNode(entry) {
                nodes.append(node)
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            if owned != 0 { IOObjectRelease(owned) }
            if kr != KERN_SUCCESS || parent == 0 { break }
            owned = parent
            entry = parent
        }
        if owned != 0 { IOObjectRelease(owned) }
        return nodes
    }

    private func usbNode(_ entry: io_registry_entry_t) -> USBNode? {
        let vendor = registryNumber(entry, "idVendor")
        let name = registryString(entry, "USB Product Name") ?? registryString(entry, "kUSBProductString") ?? ""
        let serial = registryString(entry, "USB Serial Number") ?? ""
        let container = registryString(entry, "kUSBContainerID") ?? ""
        let location = registryNumber(entry, "locationID") ?? 0
        guard vendor != nil || !name.isEmpty || !serial.isEmpty else { return nil }
        return USBNode(name: name, serial: serial, container: container, location: location)
    }

    private func registryString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return raw.takeRetainedValue() as? String
    }

    private func registryNumber(_ entry: io_registry_entry_t, _ key: String) -> UInt32? {
        guard let raw = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (raw.takeRetainedValue() as? NSNumber)?.uint32Value
    }
}
