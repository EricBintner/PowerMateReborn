import XCTest
import CoreBluetooth
@testable import PowerMateDriver

// Byte values and timings come from real hardware: the LightBlue capture in
// GitHub issue 4 (firmware 1.0.1) and traces recorded by the public Linux and
// Home Assistant implementations. Nobody on this project owns a Bluetooth
// PowerMate, so these tests are the only local check on the protocol.

final class PowerMateBLEEventTests: XCTestCase {
    func testTurnsAreOneStepInOppositeDirections() {
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x68), .rotate(1))
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x67), .rotate(-1))
    }

    func testTurnsWhilePressedAreReportedSeparately() {
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x70), .rotateWhilePressed(1))
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x69), .rotateWhilePressed(-1))
    }

    func testShortPressIsAClick() {
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x65), .click)
    }

    func testReleaseAfterAHold() {
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x66), .holdReleased)
    }

    func testHoldCodesCountUpFromOne() {
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x72), .held(step: 1))
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x74), .held(step: 3))
        XCTAssertEqual(PowerMateBLEEvent(byte: 0x77), .held(step: 6))
    }

    func testAnyOtherByteIsUnknownRatherThanARotation() {
        for byte: UInt8 in [0x00, 0x01, 0x64, 0x71, 0x78, 0xFF] {
            XCTAssertEqual(PowerMateBLEEvent(byte: byte), .unknown(byte))
        }
    }
}

final class PowerMateBLEDiscoveryTests: XCTestCase {
    private typealias Characteristic = (uuid: CBUUID, properties: CBCharacteristicProperties)

    // The PowerMate service exactly as the knob in issues 2-5 reports it.
    private let knobService: [Characteristic] = [
        (PowerMateBLEUUID.battery, .notify),
        (PowerMateBLEUUID.led, .write),
        (PowerMateBLEUUID.knob, .notify),
        (PowerMateBLEUUID.unknown, [.read, .write]),
    ]

    func testPowerMateServiceWithANotifyingKnobIsReady() {
        XCTAssertEqual(PowerMateBLEDiscovery.outcome(service: PowerMateBLEUUID.service,
                                                     characteristics: knobService), .ready)
    }

    // Issues 2-5: the read-only Device Information service was judged by the
    // knob's rule, so a working knob was disconnected every few seconds.
    func testDeviceInformationServiceIsIgnoredNotTreatedAsABrokenKnob() {
        let deviceInfo: [Characteristic] = [
            (PowerMateBLEUUID.modelNumber, .read),
            (PowerMateBLEUUID.firmwareRevision, .read),
        ]
        XCTAssertEqual(PowerMateBLEDiscovery.outcome(service: PowerMateBLEUUID.deviceInfoService,
                                                     characteristics: deviceInfo), .ignored)
    }

    func testPowerMateServiceWithoutAKnobCharacteristicIsUnusable() {
        let noKnob = knobService.filter { $0.uuid != PowerMateBLEUUID.knob }
        XCTAssertEqual(PowerMateBLEDiscovery.outcome(service: PowerMateBLEUUID.service,
                                                     characteristics: noKnob), .unusable)
    }

    func testKnobCharacteristicThatCannotNotifyIsUnusable() {
        let silentKnob: [Characteristic] = [(PowerMateBLEUUID.knob, .read)]
        XCTAssertEqual(PowerMateBLEDiscovery.outcome(service: PowerMateBLEUUID.service,
                                                     characteristics: silentKnob), .unusable)
    }

    func testPowerMateServiceWithNoCharacteristicsIsUnusable() {
        XCTAssertEqual(PowerMateBLEDiscovery.outcome(service: PowerMateBLEUUID.service,
                                                     characteristics: []), .unusable)
    }
}

final class PowerMateBLELEDTests: XCTestCase {
    func testZeroBrightnessTurnsTheLEDOff() {
        XCTAssertEqual(PowerMateBLELED.byte(forBrightness: 0), 0x80)
    }

    func testLowestBrightnessIsTheDimmestSteadyLevel() {
        XCTAssertEqual(PowerMateBLELED.byte(forBrightness: 1), 0xA1)
    }

    // 0xFF, which the app used to send for full brightness, is a blink command.
    func testFullBrightnessIsTheBrightestSteadyLevel() {
        XCTAssertEqual(PowerMateBLELED.byte(forBrightness: 255), 0xBF)
    }

    func testEveryBrightnessMapsIntoTheSteadyRangeWithoutGoingBackwards() {
        var previous: UInt8 = 0xA1
        for brightness in 1...255 {
            let byte = PowerMateBLELED.byte(forBrightness: UInt8(brightness))
            XCTAssertTrue((0xA1...0xBF).contains(byte), "brightness \(brightness) gave \(byte)")
            XCTAssertGreaterThanOrEqual(byte, previous, "brightness \(brightness) went backwards")
            previous = byte
        }
    }
}

final class PowerMateBLEGestureFilterTests: XCTestCase {
    /// Feeds (seconds, byte) notifications through a fresh filter.
    private func actions(_ timeline: [(TimeInterval, UInt8)]) -> [PowerMateBLEAction] {
        var filter = PowerMateBLEGestureFilter()
        return timeline.flatMap { filter.actions(for: PowerMateBLEEvent(byte: $0.1), at: $0.0) }
    }

    func testTurnsPassStraightThrough() {
        // recorded: turns 40-200 ms apart
        XCTAssertEqual(actions([(4.0, 0x67), (4.04, 0x67), (4.2, 0x68)]),
                       [.rotate(-1), .rotate(-1), .rotate(1)])
    }

    func testTurnsWhilePressedCountAsTurns() {
        XCTAssertEqual(actions([(0.0, 0x70), (0.1, 0x69)]), [.rotate(1), .rotate(-1)])
    }

    func testSeparatePressesAreSeparateClicks() {
        // recorded: single presses 1.4-2.6 s apart
        XCTAssertEqual(actions([(0.0, 0x65), (1.36, 0x65), (2.96, 0x65)]), [.click, .click, .click])
    }

    // The button is known to send the same press twice.
    func testRepeatedClickInsideTheQuietPeriodIsDropped() {
        XCTAssertEqual(actions([(0.0, 0x65), (0.05, 0x65), (0.6, 0x65)]), [.click])
    }

    func testDroppedRepeatsDoNotExtendTheQuietPeriod() {
        XCTAssertEqual(actions([(0.0, 0x65), (0.8, 0x65), (1.2, 0x65)]), [.click, .click])
    }

    // Recorded 2026-10-21: five pressed-turn steps, then a stray press one
    // second after the last step when the knob was let go.
    func testClickFromLettingGoAfterAPressedTurnIsDropped() {
        XCTAssertEqual(actions([(0.0, 0x69), (0.16, 0x69), (0.32, 0x69), (0.48, 0x69), (0.72, 0x69), (1.72, 0x65)]),
                       Array(repeating: .rotate(-1), count: 5))
    }

    func testClickWellAfterAPressedTurnPasses() {
        XCTAssertEqual(actions([(0.0, 0x69), (2.0, 0x65)]), [.rotate(-1), .click])
    }

    func testHoldBecomesOneLongPress() {
        XCTAssertEqual(actions([(1.0, 0x72), (2.0, 0x73), (3.0, 0x74)]), [.longPress])
    }

    func testLongPressStillFiresIfTheFirstHoldCodeIsMissed() {
        XCTAssertEqual(actions([(2.0, 0x73), (3.0, 0x74)]), [.longPress])
    }

    // The knob sends the release twice.
    func testReleaseAfterALongPressIsReportedOnce() {
        XCTAssertEqual(actions([(1.0, 0x72), (1.5, 0x66), (1.52, 0x66)]), [.longPress, .longPressReleased])
    }

    func testReleaseWithoutALongPressIsIgnored() {
        XCTAssertEqual(actions([(0.0, 0x66)]), [])
    }

    func testStrayClickAfterAHoldReleaseIsDropped() {
        XCTAssertEqual(actions([(1.0, 0x72), (1.5, 0x66), (1.9, 0x65)]), [.longPress, .longPressReleased])
    }

    func testANewLongPressCanFollowARelease() {
        XCTAssertEqual(actions([(1.0, 0x72), (1.5, 0x66), (5.0, 0x72)]),
                       [.longPress, .longPressReleased, .longPress])
    }

    // Pressing and turning is an adjustment, not a long press. On USB the
    // rotation cancels the long press for the rest of that press.
    func testHoldCodeDuringAPressedTurnIsNotALongPress() {
        XCTAssertEqual(actions([(0.0, 0x70), (0.5, 0x72)]), [.rotate(1)])
    }

    // Pausing with the button still down after a pressed turn: the knob keeps
    // sending hold codes, and none of them may switch modes mid-adjustment.
    func testHoldingStillAfterAPressedTurnIsStillNotALongPress() {
        XCTAssertEqual(actions([(0.0, 0x70), (1.0, 0x72), (2.0, 0x73), (3.0, 0x74), (4.0, 0x75), (4.3, 0x66)]),
                       [.rotate(1)])
    }

    // The release code ends the pressed-turn press, so a hold that starts
    // straight afterwards is a new press and counts.
    func testAHoldStartedRightAfterAPressedTurnPressEndsIsALongPress() {
        XCTAssertEqual(actions([(0.0, 0x70), (1.0, 0x72), (1.4, 0x66), (2.45, 0x72)]), [.rotate(1), .longPress])
    }

    func testANewPressAfterAPressedTurnCanBeALongPress() {
        XCTAssertEqual(actions([(0.0, 0x70), (0.9, 0x65), (5.0, 0x72)]), [.rotate(1), .longPress])
    }

    // A long press must always end, or a sustained Custom-mode action sticks
    // and later long presses are ignored. A plain turn or a click can only
    // happen with the button up, so either one ends a hold whose release
    // code never arrived.
    func testPlainTurnEndsALongPressWhoseReleaseWasNeverSent() {
        XCTAssertEqual(actions([(1.0, 0x72), (3.0, 0x68)]), [.longPress, .longPressReleased, .rotate(1)])
    }

    func testClickEndsALongPressWhoseReleaseWasNeverSent() {
        XCTAssertEqual(actions([(1.0, 0x72), (3.0, 0x65)]), [.longPress, .longPressReleased])
    }

    func testLongPressWorksAgainAfterEndingWithoutAReleaseCode() {
        XCTAssertEqual(actions([(1.0, 0x72), (1.5, 0x69), (2.2, 0x65), (9.0, 0x72)]),
                       [.longPress, .rotate(-1), .longPressReleased, .longPress])
    }

    func testTurningWhileHeldKeepsTheLongPressGoing() {
        var filter = PowerMateBLEGestureFilter()
        XCTAssertEqual(filter.actions(for: .held(step: 1), at: 1.0), [.longPress])
        XCTAssertEqual(filter.actions(for: .rotateWhilePressed(1), at: 1.5), [.rotate(1)])
        XCTAssertTrue(filter.isLongPressActive)
        XCTAssertEqual(filter.actions(for: .holdReleased, at: 2.5), [.longPressReleased])
    }

    func testUnknownBytesDoNothing() {
        XCTAssertEqual(actions([(0.0, 0x00), (0.1, 0xFF), (0.2, 0x71)]), [])
    }

    func testResetForgetsEarlierEvents() {
        var filter = PowerMateBLEGestureFilter()
        XCTAssertEqual(filter.actions(for: .click, at: 0.0), [.click])
        filter.reset()
        XCTAssertEqual(filter.actions(for: .click, at: 0.2), [.click])
    }

    func testLongPressStaysActiveUntilRelease() {
        var filter = PowerMateBLEGestureFilter()
        XCTAssertFalse(filter.isLongPressActive)
        _ = filter.actions(for: .held(step: 1), at: 1.0)
        XCTAssertTrue(filter.isLongPressActive)
        _ = filter.actions(for: .holdReleased, at: 2.0)
        XCTAssertFalse(filter.isLongPressActive)
    }
}

/// How long to wait before looking for the knob again after a connection ends.
/// v1.2.0-1.2.2 always started over at 2 s, which is what let a connection
/// that kept failing repeat every few seconds.
final class PowerMateBLEReconnectTests: XCTestCase {
    func testRetriesQuicklyAfterAStableSession() {
        XCTAssertEqual(PowerMateBLEReconnect.delay(afterUnstableConnections: 0), 2)
    }

    func testEachConnectionThatFailsInARowDoublesTheWait() {
        XCTAssertEqual(PowerMateBLEReconnect.delay(afterUnstableConnections: 1), 4)
        XCTAssertEqual(PowerMateBLEReconnect.delay(afterUnstableConnections: 2), 8)
        XCTAssertEqual(PowerMateBLEReconnect.delay(afterUnstableConnections: 5), 64)
    }

    func testWaitIsCappedAtFiveMinutes() {
        XCTAssertEqual(PowerMateBLEReconnect.delay(afterUnstableConnections: 8), 300)
        XCTAssertEqual(PowerMateBLEReconnect.delay(afterUnstableConnections: 500), 300)
    }
}
