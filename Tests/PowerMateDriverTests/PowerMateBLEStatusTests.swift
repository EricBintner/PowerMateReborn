import XCTest
import CoreBluetooth
@testable import PowerMateDriver

/// What an issue report says about the Bluetooth side. A report from someone
/// whose knob will not connect used to say nothing about Bluetooth at all.
final class PowerMateBLEStatusTests: XCTestCase {
    private func status(radio: PowerMateBLEStatus.Radio = .on, isConnected: Bool = false,
                        remembersKnob: Bool = false, unstableConnections: Int = 0,
                        firmware: String? = nil, batteryPercent: Int? = nil) -> PowerMateBLEStatus {
        return PowerMateBLEStatus(radio: radio, isConnected: isConnected, remembersKnob: remembersKnob,
                                  unstableConnections: unstableConnections,
                                  firmware: firmware, batteryPercent: batteryPercent)
    }

    func testAConnectedKnobReportsItsFirmwareAndBattery() {
        XCTAssertEqual(status(isConnected: true, remembersKnob: true, firmware: "1.0.1", batteryPercent: 80).summary,
                       "connected (firmware 1.0.1, battery 80%)")
    }

    func testAConnectedKnobThatHasNotReportedDetailsIsJustConnected() {
        XCTAssertEqual(status(isConnected: true, remembersKnob: true).summary, "connected")
        XCTAssertEqual(status(isConnected: true, remembersKnob: true, batteryPercent: 5).summary,
                       "connected (battery 5%)")
    }

    func testEachBluetoothStateIsNamed() {
        XCTAssertEqual(status(radio: .on).summary,
                       "not connected (Bluetooth is on; no knob has worked on this Mac yet)")
        XCTAssertEqual(status(radio: .off).summary,
                       "not connected (Bluetooth is off; no knob has worked on this Mac yet)")
        XCTAssertEqual(status(radio: .notAllowed).summary,
                       "not connected (PowerMateReborn is not allowed to use Bluetooth; no knob has worked on this Mac yet)")
        XCTAssertEqual(status(radio: .unsupported).summary,
                       "not connected (this Mac has no Bluetooth LE; no knob has worked on this Mac yet)")
        XCTAssertEqual(status(radio: .notReady).summary,
                       "not connected (Bluetooth is not ready; no knob has worked on this Mac yet)")
    }

    func testAKnobThatWorkedBeforeIsSaidToBeRemembered() {
        XCTAssertEqual(status(remembersKnob: true).summary,
                       "not connected (Bluetooth is on; a knob has worked on this Mac before)")
    }

    // The v1.2.2 loop: connections that never became usable, over and over.
    func testConnectionsThatKeepFailingAreCounted() {
        XCTAssertEqual(status(remembersKnob: true, unstableConnections: 1).summary,
                       "not connected (Bluetooth is on; a knob has worked on this Mac before; the last connection failed or dropped early)")
        XCTAssertEqual(status(unstableConnections: 4).summary,
                       "not connected (Bluetooth is on; no knob has worked on this Mac yet; the last 4 connections failed or dropped early)")
    }

    func testTheSystemsBluetoothStateMapsOntoTheReportedOne() {
        XCTAssertEqual(PowerMateBLEStatus.Radio(CBManagerState.poweredOn), .on)
        XCTAssertEqual(PowerMateBLEStatus.Radio(CBManagerState.poweredOff), .off)
        XCTAssertEqual(PowerMateBLEStatus.Radio(CBManagerState.unauthorized), .notAllowed)
        XCTAssertEqual(PowerMateBLEStatus.Radio(CBManagerState.unsupported), .unsupported)
        XCTAssertEqual(PowerMateBLEStatus.Radio(CBManagerState.resetting), .notReady)
        XCTAssertEqual(PowerMateBLEStatus.Radio(CBManagerState.unknown), .notReady)
        XCTAssertEqual(PowerMateBLEStatus.Radio(nil), .notReady, "Bluetooth has not been started")
    }
}
