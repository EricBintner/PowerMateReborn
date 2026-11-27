import XCTest
@testable import PowerMateDriver

private let knobA = "test:knob-a"
private let knobB = "test:knob-b"

private final class RecordingDelegate: PowerMateDelegate {
    var events: [String] = []
    func powerMateDidConnect(identity: String, displayName: String) { events.append("connect \(identity)") }
    func powerMateDidDisconnect(identity: String) { events.append("disconnect \(identity)") }
    func powerMateDidRotate(delta: Int, identity: String) { events.append("rotate \(delta) \(identity)") }
    func powerMateButtonPressed(identity: String) { events.append("pressed \(identity)") }
    func powerMateButtonDoubleTapped(identity: String) { events.append("doubleTapped \(identity)") }
    func powerMateButtonLongPressed(identity: String) { events.append("longPressed \(identity)") }
    func powerMateButtonReleased(identity: String) { events.append("released \(identity)") }
}

private final class StubTransport: PowerMateTransport {
    weak var transportDelegate: PowerMateTransportDelegate?
    var isConnected = true
    var identities: [String]
    var brightness: [String: UInt8] = [:]

    init(identities: [String] = [knobA, knobB]) {
        self.identities = identities
    }

    var connectedDevices: [(identity: String, displayName: String)] {
        identities.map { (identity: $0, displayName: $0) }
    }
    func owns(_ identity: String) -> Bool { identities.contains(identity) }
    func ledBrightness(for identity: String) -> UInt8 { brightness[identity] ?? 0 }
    func start() {}
    func stop() {}
    func setLEDBrightness(_ brightness: UInt8, identity: String) { self.brightness[identity] = brightness }
}

/// The Bluetooth knob times presses itself and reports finished gestures, so
/// the manager takes clicks and long presses directly instead of raw button
/// state. Gesture state is kept per knob.
final class PowerMateManagerGestureTests: XCTestCase {
    private var manager: PowerMateManager!
    private var delegate: RecordingDelegate!
    private var transport: StubTransport!

    override func setUp() {
        manager = PowerMateManager()
        delegate = RecordingDelegate()
        transport = StubTransport()
        manager.delegate = delegate
        manager.addTransport(transport)
        manager.gestureTiming = { _ in (longPress: 0.5, doubleTap: 0.05) }
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testClickBecomesASinglePressOnceTheDoubleTapIntervalPasses() {
        manager.transportDidClick(transport, identity: knobA)
        XCTAssertEqual(delegate.events, [], "must wait for a possible second tap")
        wait(0.2)
        XCTAssertEqual(delegate.events, ["pressed \(knobA)"])
    }

    func testTwoClicksInsideTheIntervalBecomeADoubleTap() {
        manager.transportDidClick(transport, identity: knobA)
        manager.transportDidClick(transport, identity: knobA)
        wait(0.2)
        XCTAssertEqual(delegate.events, ["doubleTapped \(knobA)"])
    }

    func testDeviceLongPressFiresAtOnce() {
        manager.transportDidLongPress(transport, identity: knobA)
        XCTAssertEqual(delegate.events, ["longPressed \(knobA)"])
    }

    func testLongPressCancelsAPendingSinglePress() {
        manager.transportDidClick(transport, identity: knobA)
        manager.transportDidLongPress(transport, identity: knobA)
        wait(0.2)
        XCTAssertEqual(delegate.events, ["longPressed \(knobA)"])
    }

    func testLongPressReleaseIsForwarded() {
        manager.transportDidLongPress(transport, identity: knobA)
        manager.transportDidReleaseLongPress(transport, identity: knobA)
        XCTAssertEqual(delegate.events, ["longPressed \(knobA)", "released \(knobA)"])
    }

    // Guards the USB path while tap counting is shared with the click path.
    func testRawPressAndReleaseStillBecomesASinglePress() {
        manager.transport(transport, identity: knobA, buttonStateChanged: true)
        manager.transport(transport, identity: knobA, buttonStateChanged: false)
        wait(0.2)
        XCTAssertEqual(delegate.events, ["released \(knobA)", "pressed \(knobA)"])
    }

    func testRawDoublePressStillBecomesADoubleTap() {
        for pressed in [true, false, true, false] {
            manager.transport(transport, identity: knobA, buttonStateChanged: pressed)
        }
        wait(0.2)
        XCTAssertEqual(delegate.events, ["released \(knobA)", "released \(knobA)", "doubleTapped \(knobA)"])
    }

    // Two knobs must not share tap counting: one click on each is two
    // single presses, not one double tap.
    func testClicksOnDifferentKnobsAreNotADoubleTap() {
        manager.transportDidClick(transport, identity: knobA)
        manager.transportDidClick(transport, identity: knobB)
        wait(0.2)
        XCTAssertEqual(Set(delegate.events), ["pressed \(knobA)", "pressed \(knobB)"])
        XCTAssertEqual(delegate.events.count, 2)
    }

    func testLEDWritesGoOnlyToTheKnobAskedFor() {
        manager.setLEDBrightness(200, for: knobA)
        XCTAssertEqual(transport.brightness[knobA], 200)
        XCTAssertNil(transport.brightness[knobB])
    }
}
