import Foundation
import CoreBluetooth

// Griffin PowerMate Bluetooth BLE identifiers (reverse-engineered from PowerMateKit.framework)
private let kPowerMateBLEServiceUUID        = CBUUID(string: "25598CF7-4240-40A6-9910-080F19F91EBC")
private let kPowerMateBLECharRotationUUID   = CBUUID(string: "9CF53570-DDD9-47F3-BA63-09ACEFC60415")
private let kPowerMateBLECharButtonUUID     = CBUUID(string: "50F09CC9-FE1D-4C79-A962-B3A7CD3E5584")
private let kPowerMateBLECharLEDUUID        = CBUUID(string: "847D189E-86EE-4BD2-966F-800832B1259D")
private let kPowerMateBLECharUnknownUUID    = CBUUID(string: "c5cf8ae4-6988-409f-9ec4-f9daa9147d15")

// Standard BLE UUIDs for device identification
private let kDeviceInfoServiceUUID          = CBUUID(string: "180A")
private let kFirmwareRevisionCharUUID       = CBUUID(string: "2A26")
private let kModelNumberCharUUID            = CBUUID(string: "2A24")

/// BLE transport for the Griffin PowerMate Bluetooth.
/// Reports raw hardware events (rotation, button state) to the PowerMateManager
/// via the PowerMateTransportDelegate protocol. No gesture detection here.
class PowerMateBLETransport: NSObject, PowerMateTransport {
    weak var transportDelegate: PowerMateTransportDelegate?

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var ledCharacteristic: CBCharacteristic?
    private var lastButtonState: Bool = false

    // LED state
    private(set) var ledBrightness: UInt8 = 0

    // Reconnection
    private var shouldScan: Bool = false

    var isConnected: Bool {
        return peripheral?.state == .connected
    }

    override init() {
        super.init()
    }

    // MARK: - PowerMateTransport

    func start() {
        shouldScan = true
        // CBCentralManager init triggers a state update callback;
        // scanning begins in centralManagerDidUpdateState when state == .poweredOn
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    func stop() {
        shouldScan = false
        if let peripheral = peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        centralManager?.stopScan()
        peripheral = nil
        ledCharacteristic = nil
    }

    func setLEDBrightness(_ brightness: UInt8) {
        ledBrightness = brightness
        guard let char = ledCharacteristic, let peripheral = peripheral, peripheral.state == .connected else { return }
        let data = Data([brightness])
        peripheral.writeValue(data, for: char, type: .withResponse)
    }

    // MARK: - Private

    private func startScanning() {
        guard let cm = centralManager, cm.state == .poweredOn, shouldScan else { return }
        NSLog("BLE: Scanning for PowerMate Bluetooth...")
        cm.scanForPeripherals(withServices: [kPowerMateBLEServiceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }
}

// MARK: - CBCentralManagerDelegate

extension PowerMateBLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            NSLog("BLE: Bluetooth powered on")
            startScanning()
        case .poweredOff:
            NSLog("BLE: Bluetooth powered off")
        case .unauthorized:
            NSLog("BLE: Bluetooth unauthorized — check System Settings > Privacy > Bluetooth")
        case .unsupported:
            NSLog("BLE: Bluetooth LE not supported on this hardware")
        default:
            NSLog("BLE: Bluetooth state: %d", central.state.rawValue)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        NSLog("BLE: Discovered PowerMate Bluetooth: %@ (RSSI: %@)", name, RSSI)

        // Stop scanning once we find one
        central.stopScan()

        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("BLE: Connected to PowerMate Bluetooth")
        peripheral.discoverServices([kPowerMateBLEServiceUUID, kDeviceInfoServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        NSLog("BLE: Failed to connect: %@", error?.localizedDescription ?? "unknown")
        self.peripheral = nil
        // Retry scanning
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        NSLog("BLE: Disconnected from PowerMate Bluetooth: %@", error?.localizedDescription ?? "clean")
        self.ledCharacteristic = nil
        self.lastButtonState = false

        DispatchQueue.main.async {
            self.transportDelegate?.transportDidDisconnect(self)
        }

        // Auto-reconnect
        if shouldScan {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startScanning()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PowerMateBLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            NSLog("BLE: Discovered service: %@", service.uuid.uuidString)
            if service.uuid == kPowerMateBLEServiceUUID {
                peripheral.discoverCharacteristics([
                    kPowerMateBLECharRotationUUID,
                    kPowerMateBLECharButtonUUID,
                    kPowerMateBLECharLEDUUID,
                    kPowerMateBLECharUnknownUUID
                ], for: service)
            } else if service.uuid == kDeviceInfoServiceUUID {
                peripheral.discoverCharacteristics([kFirmwareRevisionCharUUID, kModelNumberCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        var subscribedCount = 0

        for char in chars {
            NSLog("BLE: Characteristic %@ — properties: %d", char.uuid.uuidString, char.properties.rawValue)

            if char.uuid == kPowerMateBLECharRotationUUID || char.uuid == kPowerMateBLECharButtonUUID {
                // Subscribe for notifications (rotation ticks, button state)
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                    subscribedCount += 1
                    NSLog("BLE: Subscribed to notifications for %@", char.uuid.uuidString)
                }
            } else if char.uuid == kPowerMateBLECharLEDUUID {
                ledCharacteristic = char
                NSLog("BLE: Found LED characteristic")
                // Sync current LED state
                if ledBrightness > 0 {
                    let data = Data([ledBrightness])
                    peripheral.writeValue(data, for: char, type: .withResponse)
                }
            } else if char.uuid == kFirmwareRevisionCharUUID || char.uuid == kModelNumberCharUUID {
                peripheral.readValue(for: char)
            }
        }

        // If we subscribed to at least one characteristic, we're operational
        if subscribedCount > 0 {
            DispatchQueue.main.async {
                self.transportDelegate?.transportDidConnect(self)
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

        // Device info characteristics (just log them)
        if characteristic.uuid == kFirmwareRevisionCharUUID {
            let fw = String(data: data, encoding: .utf8) ?? "?"
            NSLog("BLE: Firmware revision: %@", fw)
            return
        }
        if characteristic.uuid == kModelNumberCharUUID {
            let model = String(data: data, encoding: .utf8) ?? "?"
            NSLog("BLE: Model number: %@", model)
            return
        }

        // PowerMate data characteristics
        // The BLE PowerMate sends rotation and button data via characteristic notifications.
        // Based on reverse engineering of PowerMateKit:
        // - Rotation: signed byte delta (similar to USB report[1])
        // - Button: boolean state
        //
        // NOTE: The exact byte layout will need verification with real hardware.
        // The mapping below is our best guess from the framework analysis.
        // If the data format doesn't match, we log the raw bytes for debugging.

        if characteristic.uuid == kPowerMateBLECharRotationUUID {
            guard data.count >= 1 else { return }
            let delta = Int(Int8(bitPattern: data[0]))
            if delta != 0 {
                DispatchQueue.main.async {
                    self.transportDelegate?.transport(self, didRotate: delta)
                }
            }
        } else if characteristic.uuid == kPowerMateBLECharButtonUUID {
            guard data.count >= 1 else { return }
            let pressed = data[0] != 0
            if pressed != lastButtonState {
                lastButtonState = pressed
                DispatchQueue.main.async {
                    self.transportDelegate?.transport(self, buttonStateChanged: pressed)
                }
            }
        } else {
            // Unknown characteristic — log raw bytes for future analysis
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            NSLog("BLE: Unknown char %@ data: %@", characteristic.uuid.uuidString, hex)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            NSLog("BLE: Write error for %@: %@", characteristic.uuid.uuidString, error.localizedDescription)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            NSLog("BLE: Notify state error for %@: %@", characteristic.uuid.uuidString, error.localizedDescription)
        } else {
            NSLog("BLE: Notify %@ for %@", characteristic.isNotifying ? "ON" : "OFF", characteristic.uuid.uuidString)
        }
    }
}
