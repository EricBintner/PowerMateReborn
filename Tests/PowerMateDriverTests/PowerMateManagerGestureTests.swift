import XCTest
@testable import PowerMateDriver

private final class RecordingDelegate: PowerMateDelegate {
    var events: [String] = []
    func powerMateDidConnect() { events.append("connect") }
    func powerMateDidDisconnect() { events.append("disconnect") }
    func powerMateDidRotate(delta: Int) { events.append("rotate \(delta)") }
    func powerMateButtonPressed() { events.append("pressed") }
    func powerMateButtonDoubleTapped() { events.append("doubleTapped") }
    func powerMateButtonLongPressed() { events.append("longPressed") }
    func powerMateButtonReleased() { events.append("released") }
}

private final class StubTransport: PowerMateTransport {
    weak var transportDelegate: PowerMateTransportDelegate?
    var isConnected = true
    var ledBrightness: UInt8 = 0
    func start() {}
    func stop() {}
    func setLEDBrightness(_ brightness: UInt8) { ledBrightness = brightness }
}

/// The Bluetooth knob times presses itself and reports finished gestures, so
/// the manager takes clicks and long presses directly instead of raw button
/// state.
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
        manager.doubleTapInterval = 0.05
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testClickBecomesASinglePressOnceTheDoubleTapIntervalPasses() {
        manager.transportDidClick(transport)
        XCTAssertEqual(delegate.events, [], "must wait for a possible second tap")
        wait(0.2)
        XCTAssertEqual(delegate.events, ["pressed"])
    }

    func testTwoClicksInsideTheIntervalBecomeADoubleTap() {
        manager.transportDidClick(transport)
        manager.transportDidClick(transport)
        wait(0.2)
        XCTAssertEqual(delegate.events, ["doubleTapped"])
    }

    func testDeviceLongPressFiresAtOnce() {
        manager.transportDidLongPress(transport)
        XCTAssertEqual(delegate.events, ["longPressed"])
    }

    func testLongPressCancelsAPendingSinglePress() {
        manager.transportDidClick(transport)
        manager.transportDidLongPress(transport)
        wait(0.2)
        XCTAssertEqual(delegate.events, ["longPressed"])
    }

    func testLongPressReleaseIsForwarded() {
        manager.transportDidLongPress(transport)
        manager.transportDidReleaseLongPress(transport)
        XCTAssertEqual(delegate.events, ["longPressed", "released"])
    }

    // Guards the USB path while tap counting is shared with the click path.
    func testRawPressAndReleaseStillBecomesASinglePress() {
        manager.transport(transport, buttonStateChanged: true)
        manager.transport(transport, buttonStateChanged: false)
        wait(0.2)
        XCTAssertEqual(delegate.events, ["released", "pressed"])
    }

    func testRawDoublePressStillBecomesADoubleTap() {
        for pressed in [true, false, true, false] {
            manager.transport(transport, buttonStateChanged: pressed)
        }
        wait(0.2)
        XCTAssertEqual(delegate.events, ["released", "released", "doubleTapped"])
    }
}
