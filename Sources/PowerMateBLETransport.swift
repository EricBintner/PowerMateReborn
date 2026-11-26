import Foundation
import CoreBluetooth

/// BLE transport for the Griffin PowerMate Bluetooth.
///
/// The protocol itself (what each byte means, which service decides whether
/// the knob is usable, LED bytes, filtering of the button's stray events)
/// lives in PowerMateBLEProtocol.swift, where it is unit-tested. This class
/// only drives CoreBluetooth and forwards the results to PowerMateManager.
class PowerMateBLETransport: NSObject, PowerMateTransport {
    weak var transportDelegate: PowerMateTransportDelegate?

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var ledCharacteristic: CBCharacteristic?

    /// Knob notifications are confirmed on and the manager has been told.
    private var isOperational = false
    /// When this connection became usable (system uptime).
    private var operationalSince: TimeInterval?
    /// Connections in a row that failed, never became usable, or dropped
    /// before they were stable. Sets the wait before the next rescan.
    private var unstableConnections = 0
    private var gestures = PowerMateBLEGestureFilter()

    // LED state
    private(set) var ledBrightness: UInt8 = 0
    /// Last LED byte written on this connection. The app sets the LED on
    /// every knob step, but the knob only has 31 steady levels.
    private var lastLEDByte: UInt8?

    private var lastBatteryLevel: UInt8?
    private var firmwareRevision: String?

    /// Knob turns still to be logged on this connection: a sample, so an
    /// issue report shows the decoding without the log filling with turns.
    private var turnsLeftToLog = 0
    private let turnsLoggedPerConnection = 20

    // Reconnection
    private var shouldScan: Bool = false
    /// The knob this Mac last used (see requestKnownKnob).
    private let knownKnob = PowerMateBLEKnownKnob()

    // Scan timeout: an endless scanForPeripherals keeps the Bluetooth radio
    // busy whenever no BLE PowerMate is in range (contributing to
    // bluetoothd's PreventUserIdleSystemSleep assertion). Scan for a window,
    // then stop and retry later with a capped backoff.
    private var scanTimeoutTimer: Timer?
    private var scanRetryTimer: Timer?
    private var scanRetryDelay: TimeInterval = 2.0
    private let scanWindow: TimeInterval = 10.0
    private let maxScanRetryDelay = PowerMateBLEReconnect.maxDelay

    // A connection that has not become usable this long after connecting is
    // dropped, whatever the reason, instead of sitting connected but dead.
    private var setupTimeoutTimer: Timer?
    private let setupTimeout: TimeInterval = 10.0

    var isConnected: Bool {
        return isOperational && peripheral?.state == .connected
    }

    /// What the Bluetooth side is doing right now, for issue reports.
    var status: PowerMateBLEStatus {
        return PowerMateBLEStatus(radio: PowerMateBLEStatus.Radio(centralManager?.state),
                                  isConnected: isConnected,
                                  remembersKnob: knownKnob.identifier != nil,
                                  unstableConnections: unstableConnections,
                                  firmware: firmwareRevision,
                                  batteryPercent: lastBatteryLevel.map { Int($0) })
    }

    override init() {
        super.init()
    }

    // MARK: - PowerMateTransport

    func start() {
        shouldScan = true
        unstableConnections = 0
        scanRetryDelay = PowerMateBLEReconnect.firstDelay
        // CBCentralManager init triggers a state update callback;
        // scanning begins in centralManagerDidUpdateState when state == .poweredOn
        // Don't show the system "Turn on Bluetooth?" nag — most users run the
        // USB PowerMate and shouldn't be prompted about Bluetooth.
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    func stop() {
        shouldScan = false
        if let peripheral = peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        centralManager?.stopScan()
        invalidateScanTimers()
        connectionEnded()
    }

    func setLEDBrightness(_ brightness: UInt8) {
        ledBrightness = brightness
        writeLED()
    }

    // MARK: - Private

    private func writeLED() {
        guard let char = ledCharacteristic, let peripheral = peripheral, peripheral.state == .connected else { return }
        let byte = PowerMateBLELED.byte(forBrightness: ledBrightness)
        guard byte != lastLEDByte else { return }
        lastLEDByte = byte
        let type: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data([byte]), for: char, type: type)
    }

    private func startScanning() {
        guard let cm = centralManager, cm.state == .poweredOn, shouldScan else { return }
        NSLog("BLE: Scanning for PowerMate Bluetooth...")
        cm.scanForPeripherals(withServices: [PowerMateBLEUUID.service], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // Time-box the scan: scanning forever keeps the radio busy (and
        // bluetoothd awake) when no BLE PowerMate is in range.
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: scanWindow, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.centralManager?.stopScan()
            NSLog("BLE: No device found in %.0fs — stopping scan, retrying in %.0fs", self.scanWindow, self.scanRetryDelay)
            self.scheduleScanRetry()
        }
    }

    private func scheduleScanRetry() {
        scanRetryTimer?.invalidate()
        scanRetryTimer = Timer.scheduledTimer(withTimeInterval: scanRetryDelay, repeats: false) { [weak self] _ in
            guard let self = self, self.shouldScan, self.peripheral?.state != .connected else { return }
            // Exponential backoff capped at 5 minutes
            self.scanRetryDelay = min(self.scanRetryDelay * 2, self.maxScanRetryDelay)
            self.startLooking()
        }
    }

    /// Looks for a knob in both ways: a time-boxed scan, which finds any
    /// PowerMate, and a standing request for the one this Mac already knows.
    private func startLooking() {
        startScanning()
        requestKnownKnob()
    }

    /// Asks the system to connect to the knob this Mac last used whenever it
    /// next shows up. An idle knob advertises only in short bursts minutes
    /// apart, which a time-boxed scan mostly misses; this request needs no
    /// scan and does not time out.
    ///
    /// Nothing is remembered until a Bluetooth knob has worked here, so
    /// USB-only users never make this request. It is only ever issued from
    /// startLooking, which runs when Bluetooth turns on and when the retry
    /// timer fires, so a knob that keeps failing is retried on the same
    /// growing delay as the scan, never immediately.
    private func requestKnownKnob() {
        guard let cm = centralManager, cm.state == .poweredOn, shouldScan,
              let identifier = knownKnob.identifier else { return }
        // Already connected to, connecting to, or waiting on a knob.
        if let current = peripheral, current.state != .disconnected { return }

        guard let known = cm.retrievePeripherals(withIdentifiers: [identifier]).first else {
            NSLog("BLE: The remembered knob is no longer known to this Mac — forgetting it")
            knownKnob.forget()
            return
        }
        NSLog("BLE: Waiting for the remembered knob to reappear")
        // The request lasts only while the peripheral is retained.
        peripheral = known
        known.delegate = self
        cm.connect(known, options: nil)
    }

    private func invalidateScanTimers() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        scanRetryTimer?.invalidate()
        scanRetryTimer = nil
    }

    private func startSetupTimeout(for peripheral: CBPeripheral) {
        setupTimeoutTimer?.invalidate()
        setupTimeoutTimer = Timer.scheduledTimer(withTimeInterval: setupTimeout, repeats: false) { [weak self, weak peripheral] _ in
            guard let self = self, let peripheral = peripheral, !self.isOperational else { return }
            NSLog("BLE: Knob not ready %.0fs after connecting — dropping this device", self.setupTimeout)
            self.dropUnusablePeripheral(peripheral)
        }
    }

    /// Disconnects a device we cannot use. didDisconnectPeripheral then
    /// counts it as an unstable connection, so the rescan waits longer each
    /// time and an unusable device is never reconnected in a tight loop.
    private func dropUnusablePeripheral(_ peripheral: CBPeripheral) {
        centralManager?.cancelPeripheralConnection(peripheral)
        scheduleScanRetry()
    }

    /// Knob notifications are on: the device is usable.
    private func becomeOperational() {
        // A confirmation can arrive after the setup timeout has already
        // given up on this connection.
        guard !isOperational, peripheral?.state == .connected else { return }
        isOperational = true
        operationalSince = ProcessInfo.processInfo.systemUptime
        setupTimeoutTimer?.invalidate()
        setupTimeoutTimer = nil
        gestures.reset()
        turnsLeftToLog = turnsLoggedPerConnection
        writeLED()
        if let identifier = peripheral?.identifier, knownKnob.identifier != identifier {
            knownKnob.remember(identifier)
            NSLog("BLE: Remembering this knob so it can reconnect without a scan")
        }
        DispatchQueue.main.async {
            self.transportDelegate?.transportDidConnect(self)
        }
    }

    /// Clears per-connection state, however the link ended, and tells the
    /// manager if it had been told about the connection.
    /// Returns how long the connection was usable, or nil if it never was.
    @discardableResult
    private func connectionEnded() -> TimeInterval? {
        let wasOperational = isOperational
        let usableFor = operationalSince.map { ProcessInfo.processInfo.systemUptime - $0 }
        let longPressWasActive = gestures.isLongPressActive
        isOperational = false
        operationalSince = nil
        setupTimeoutTimer?.invalidate()
        setupTimeoutTimer = nil
        ledCharacteristic = nil
        lastLEDByte = nil
        lastBatteryLevel = nil
        firmwareRevision = nil
        gestures.reset()
        peripheral = nil

        if wasOperational {
            DispatchQueue.main.async {
                // A hold in progress can never be released now. End it so a
                // sustained Custom-mode action doesn't stay on.
                if longPressWasActive {
                    self.transportDelegate?.transportDidReleaseLongPress(self)
                }
                self.transportDelegate?.transportDidDisconnect(self)
            }
        }
        return usableFor
    }

    /// Schedules the next rescan after a connection attempt ended. A stable
    /// session starts over quickly; anything else waits longer each time.
    private func rescanAfterConnectionEnded(usableFor: TimeInterval?) {
        if let usableFor = usableFor, usableFor >= PowerMateBLEReconnect.stableSession {
            unstableConnections = 0
        } else {
            unstableConnections += 1
        }
        scanRetryDelay = PowerMateBLEReconnect.delay(afterUnstableConnections: unstableConnections)
        scheduleScanRetry()
    }

    private func handleKnobData(_ data: Data) {
        guard isOperational, let byte = data.first else { return }
        let event = PowerMateBLEEvent(byte: byte)
        let actions = gestures.actions(for: event, at: ProcessInfo.processInfo.systemUptime)
        logKnobEvent(data, event: event, ignored: actions.isEmpty)

        guard !actions.isEmpty else { return }
        DispatchQueue.main.async {
            guard let delegate = self.transportDelegate else { return }
            for action in actions {
                switch action {
                case .rotate(let delta):
                    delegate.transport(self, didRotate: delta)
                case .click:
                    delegate.transportDidClick(self)
                case .longPress:
                    delegate.transportDidLongPress(self)
                case .longPressReleased:
                    delegate.transportDidReleaseLongPress(self)
                }
            }
        }
    }

    /// Logs the raw bytes next to how they were read. Button events are
    /// always logged; turns only for the first few of each connection.
    private func logKnobEvent(_ data: Data, event: PowerMateBLEEvent, ignored: Bool) {
        var isTurn = false
        switch event {
        case .rotate, .rotateWhilePressed: isTurn = true
        default: break
        }
        if isTurn {
            guard turnsLeftToLog > 0 else { return }
            turnsLeftToLog -= 1
        }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        NSLog("BLE: Knob %@ = %@%@", hex, String(describing: event), ignored ? " (ignored)" : "")
        if isTurn && turnsLeftToLog == 0 {
            NSLog("BLE: Further turns on this connection are not logged")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension PowerMateBLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            NSLog("BLE: Bluetooth powered on")
            startLooking()
            return
        case .poweredOff:
            NSLog("BLE: Bluetooth powered off")
        case .unauthorized:
            NSLog("BLE: Bluetooth unauthorized — check System Settings > Privacy > Bluetooth")
        case .unsupported:
            NSLog("BLE: Bluetooth LE not supported on this hardware")
        default:
            NSLog("BLE: Bluetooth state: %d", central.state.rawValue)
        }
        // Bluetooth is not available: any connection is gone, and it may go
        // without a disconnect callback.
        invalidateScanTimers()
        if let usableFor = connectionEnded(), usableFor >= PowerMateBLEReconnect.stableSession {
            // A stable session ended here rather than in didDisconnectPeripheral.
            unstableConnections = 0
            scanRetryDelay = PowerMateBLEReconnect.firstDelay
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        NSLog("BLE: Discovered PowerMate Bluetooth: %@ (RSSI: %@)", name, RSSI)

        // Stop scanning once we find one
        central.stopScan()

        // A standing request for some other knob is no longer wanted.
        if let pending = self.peripheral, pending.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(pending)
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else {
            // A request that was replaced or given up on completed anyway.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        NSLog("BLE: Connected to PowerMate Bluetooth")
        // Connected: the scan window and its retry are finished business.
        central.stopScan()
        invalidateScanTimers()
        startSetupTimeout(for: peripheral)
        peripheral.discoverServices([PowerMateBLEUUID.service, PowerMateBLEUUID.deviceInfoService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        NSLog("BLE: Failed to connect: %@", error?.localizedDescription ?? "unknown")
        self.peripheral = nil
        // The device is nearby, so retry soon, but wait longer each time it
        // fails again. Close the scan window as well: left open, it could
        // find the knob and try again without waiting.
        central.stopScan()
        invalidateScanTimers()
        rescanAfterConnectionEnded(usableFor: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Not the current knob: a request that was replaced, or a connection
        // already cleaned up when Bluetooth went off or the app stopped.
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        NSLog("BLE: Disconnected from PowerMate Bluetooth: %@", error?.localizedDescription ?? "clean")
        let usableFor = connectionEnded()

        // Auto-reconnect. Start over quickly after a stable session. A
        // connection that never became usable, or dropped straight away,
        // waits longer each time, so it cannot repeat every few seconds
        // (v1.2.0-1.2.2 did that to working knobs).
        if shouldScan {
            rescanAfterConnectionEnded(usableFor: usableFor)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PowerMateBLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            NSLog("BLE: Service discovery failed: %@", error.localizedDescription)
        }
        for service in peripheral.services ?? [] {
            NSLog("BLE: Discovered service: %@", service.uuid.uuidString)
            if service.uuid == PowerMateBLEUUID.service {
                peripheral.discoverCharacteristics([
                    PowerMateBLEUUID.knob,
                    PowerMateBLEUUID.battery,
                    PowerMateBLEUUID.led,
                    PowerMateBLEUUID.unknown
                ], for: service)
            } else if service.uuid == PowerMateBLEUUID.deviceInfoService {
                peripheral.discoverCharacteristics([PowerMateBLEUUID.firmwareRevision, PowerMateBLEUUID.modelNumber], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            NSLog("BLE: Characteristic discovery failed for %@: %@", service.uuid.uuidString, error.localizedDescription)
        }
        let characteristics = service.characteristics ?? []
        for char in characteristics {
            NSLog("BLE: Characteristic %@ — properties: %d", char.uuid.uuidString, char.properties.rawValue)
        }

        // This callback runs once per service. Only the PowerMate service
        // says whether the knob is usable; the Device Information service is
        // read-only by design and must never count against the connection.
        let outcome = PowerMateBLEDiscovery.outcome(
            service: service.uuid,
            characteristics: characteristics.map { (uuid: $0.uuid, properties: $0.properties) })

        switch outcome {
        case .ignored:
            for char in characteristics
            where char.uuid == PowerMateBLEUUID.firmwareRevision || char.uuid == PowerMateBLEUUID.modelNumber {
                peripheral.readValue(for: char)
            }

        case .unusable:
            NSLog("BLE: No knob characteristic to subscribe to — dropping this device")
            dropUnusablePeripheral(peripheral)

        case .ready:
            for char in characteristics {
                if char.uuid == PowerMateBLEUUID.knob
                    || (char.uuid == PowerMateBLEUUID.battery && char.properties.contains(.notify)) {
                    // The connection counts as usable once the knob's
                    // subscription is confirmed (didUpdateNotificationStateFor).
                    peripheral.setNotifyValue(true, for: char)
                    NSLog("BLE: Subscribed to notifications for %@", char.uuid.uuidString)
                } else if char.uuid == PowerMateBLEUUID.led {
                    ledCharacteristic = char
                    NSLog("BLE: Found LED characteristic")
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else {
            if let error = error {
                NSLog("BLE: Error reading %@: %@", characteristic.uuid.uuidString, error.localizedDescription)
            }
            return
        }

        switch characteristic.uuid {
        case PowerMateBLEUUID.knob:
            handleKnobData(data)

        case PowerMateBLEUUID.battery:
            // One byte, a percentage. Logged when it changes.
            guard let level = data.first, level != lastBatteryLevel else { return }
            lastBatteryLevel = level
            NSLog("BLE: Battery %d%%", level)

        case PowerMateBLEUUID.firmwareRevision:
            firmwareRevision = String(data: data, encoding: .utf8)
            NSLog("BLE: Firmware revision: %@", firmwareRevision ?? "?")

        case PowerMateBLEUUID.modelNumber:
            NSLog("BLE: Model number: %@", String(data: data, encoding: .utf8) ?? "?")

        default:
            // Unknown characteristic — log raw bytes for future analysis
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            NSLog("BLE: Unknown char %@ data: %@", characteristic.uuid.uuidString, hex)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            NSLog("BLE: Write error for %@: %@", characteristic.uuid.uuidString, error.localizedDescription)
            if characteristic.uuid == PowerMateBLEUUID.led {
                lastLEDByte = nil  // not applied: let the next LED update try again
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral else { return }
        let isKnob = characteristic.uuid == PowerMateBLEUUID.knob
        if let error = error {
            NSLog("BLE: Notify state error for %@: %@", characteristic.uuid.uuidString, error.localizedDescription)
            if isKnob {
                NSLog("BLE: Cannot receive knob events — dropping this device")
                dropUnusablePeripheral(peripheral)
            }
            return
        }
        NSLog("BLE: Notify %@ for %@", characteristic.isNotifying ? "ON" : "OFF", characteristic.uuid.uuidString)
        if isKnob && characteristic.isNotifying {
            becomeOperational()
        }
    }
}
