import Foundation
import IOKit.pwr_mgt

// MARK: - High-Level Delegate (consumed by AppDelegate)

protocol PowerMateDelegate: AnyObject {
    func powerMateDidConnect()
    func powerMateDidDisconnect()
    func powerMateDidRotate(delta: Int)
    func powerMateButtonPressed()       // single press
    func powerMateButtonDoubleTapped()  // two presses within doubleTapInterval
    func powerMateButtonLongPressed()   // hold >= longPressThreshold
    func powerMateButtonReleased()      // raw button-up (for extended press / sustain)
}

// MARK: - Transport Protocol

/// Events from a hardware transport (USB or BLE).
/// Transports report what the hardware says and leave gesture detection to
/// PowerMateManager. The USB knob reports raw button state. The Bluetooth
/// knob times presses in its own firmware and only reports finished clicks
/// and holds, so it uses the click and long-press calls instead.
protocol PowerMateTransportDelegate: AnyObject {
    func transportDidConnect(_ transport: PowerMateTransport)
    func transportDidDisconnect(_ transport: PowerMateTransport)
    func transport(_ transport: PowerMateTransport, didRotate delta: Int)
    /// Raw button state (USB).
    func transport(_ transport: PowerMateTransport, buttonStateChanged pressed: Bool)
    /// A finished short press, timed by the device (Bluetooth).
    func transportDidClick(_ transport: PowerMateTransport)
    /// The device reports the button has been held long enough (Bluetooth).
    func transportDidLongPress(_ transport: PowerMateTransport)
    /// The button was let go after `transportDidLongPress` (Bluetooth).
    func transportDidReleaseLongPress(_ transport: PowerMateTransport)
}

/// A hardware transport that can communicate with a PowerMate device.
protocol PowerMateTransport: AnyObject {
    var transportDelegate: PowerMateTransportDelegate? { get set }
    var isConnected: Bool { get }
    var ledBrightness: UInt8 { get }
    func start()
    func stop()
    func setLEDBrightness(_ brightness: UInt8)
}

// MARK: - PowerMateManager

/// Central manager that owns all transports (USB, BLE) and performs unified gesture detection.
/// AppDelegate talks only to this class via `PowerMateDelegate`.
class PowerMateManager: NSObject, PowerMateTransportDelegate {
    weak var delegate: PowerMateDelegate?

    // Transports
    private var transports: [PowerMateTransport] = []

    // Gesture detection (extracted from the old PowerMateHID)
    var longPressThreshold: TimeInterval = 0.5   // seconds
    var doubleTapInterval: TimeInterval = 0.3    // max gap between taps
    private var buttonDownTime: Date?
    private var longPressTimer: Timer?
    private var longPressFired: Bool = false
    private var tapCount: Int = 0
    private var singleTapTimer: Timer?
    private var rotatedWhilePressed: Bool = false
    private var lastButtonState: Bool = false

    // LED state (broadcast to all transports)
    private(set) var ledBrightness: UInt8 = 0

    // Knob use counts as user activity, like a mouse: it wakes the displays
    // and postpones display sleep. macOS no longer sees the seized USB knob
    // (and never saw the BLE one), so declare it ourselves, at most once a second.
    private var userActivityAssertion = IOPMAssertionID(0)
    private var lastUserActivity = Date.distantPast

    // LED output reports block the main thread until the knob accepts them
    // (~8 ms, the USB interval). Keep the latest byte and send it at most
    // 20 times a second, same shape as the volume throttle.
    private var pendingLED: UInt8?
    private var lastLEDSent: UInt8?
    private var lastLEDTime: TimeInterval = 0
    private var ledTimer: Timer?
    private let ledMinInterval: TimeInterval = 0.05

    override init() {
        super.init()
    }

    // MARK: - Transport Management

    func addTransport(_ transport: PowerMateTransport) {
        transport.transportDelegate = self
        transports.append(transport)
    }

    func start() {
        for transport in transports {
            transport.start()
        }
    }

    func stop() {
        if pendingLED != nil {
            flushLED()
        }
        ledTimer?.invalidate()
        ledTimer = nil
        for transport in transports {
            transport.stop()
        }
    }

    var isConnected: Bool {
        return transports.contains(where: { $0.isConnected })
    }

    // For issue reports: each kind of knob is reported on its own, so a
    // report says what Bluetooth is doing even when nothing is connected.

    var isUSBConnected: Bool {
        return transports.contains(where: { $0 is PowerMateUSBTransport && $0.isConnected })
    }

    var bluetoothStatus: PowerMateBLEStatus? {
        return transports.lazy.compactMap({ $0 as? PowerMateBLETransport }).first?.status
    }

    // MARK: - LED Control

    func setLEDBrightness(_ brightness: UInt8) {
        ledBrightness = brightness
        if pendingLED == brightness { return }
        if pendingLED == nil, lastLEDSent == brightness { return }

        pendingLED = brightness
        let elapsed = ProcessInfo.processInfo.systemUptime - lastLEDTime
        if elapsed >= ledMinInterval {
            flushLED()
        } else {
            ledTimer?.invalidate()
            let remaining = ledMinInterval - elapsed
            let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
                self?.flushLED()
            }
            ledTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func flushLED() {
        ledTimer?.invalidate()
        ledTimer = nil
        guard let brightness = pendingLED else { return }
        pendingLED = nil
        lastLEDTime = ProcessInfo.processInfo.systemUptime
        lastLEDSent = brightness
        for transport in transports where transport.isConnected {
            transport.setLEDBrightness(brightness)
        }
    }

    // MARK: - PowerMateTransportDelegate

    func transportDidConnect(_ transport: PowerMateTransport) {
        // Sync LED state to newly connected device
        transport.setLEDBrightness(ledBrightness)
        delegate?.powerMateDidConnect()
    }

    func transportDidDisconnect(_ transport: PowerMateTransport) {
        // Clean up pending gesture timers if no devices remain
        if !isConnected {
            resetGestureState()
        }
        delegate?.powerMateDidDisconnect()
    }

    func transport(_ transport: PowerMateTransport, didRotate delta: Int) {
        declareUserActivity()
        if buttonDownTime != nil {
            rotatedWhilePressed = true
            // A press-rotate is not a long press: cancel the pending long-press
            // timer so it doesn't fire (mode switch) mid-adjustment.
            longPressTimer?.invalidate()
            longPressTimer = nil
        }
        delegate?.powerMateDidRotate(delta: delta)
    }

    func transport(_ transport: PowerMateTransport, buttonStateChanged pressed: Bool) {
        guard pressed != lastButtonState else { return }
        lastButtonState = pressed
        // Before gesture handling: a double tap ends here by sleeping the
        // displays, and that must come after this activity, not before it.
        declareUserActivity()
        if pressed {
            onButtonDown()
        } else {
            onButtonUp()
        }
    }

    func transportDidClick(_ transport: PowerMateTransport) {
        declareUserActivity()
        registerTap()
    }

    func transportDidLongPress(_ transport: PowerMateTransport) {
        declareUserActivity()
        fireLongPress()
    }

    func transportDidReleaseLongPress(_ transport: PowerMateTransport) {
        delegate?.powerMateButtonReleased()
    }

    private func declareUserActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastUserActivity) >= 1.0 else { return }
        lastUserActivity = now
        IOPMAssertionDeclareUserActivity("PowerMate knob" as CFString, kIOPMUserActiveLocal, &userActivityAssertion)
    }

    // MARK: - Gesture Detection

    private func onButtonDown() {
        buttonDownTime = Date()
        longPressFired = false
        rotatedWhilePressed = false

        // Cancel pending single-tap timer (we got another press)
        singleTapTimer?.invalidate()
        singleTapTimer = nil

        // Start long-press timer. Run-loop mode .common so the timer keeps
        // firing even while a menu's event-tracking loop is open.
        longPressTimer?.invalidate()
        longPressTimer = Timer(timeInterval: longPressThreshold, target: self, selector: #selector(handleLongPress(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(longPressTimer!, forMode: .common)
    }

    private func onButtonUp() {
        longPressTimer?.invalidate()
        longPressTimer = nil

        // Always notify raw release (for extended press / sustain actions)
        delegate?.powerMateButtonReleased()

        guard !longPressFired else {
            buttonDownTime = nil
            longPressFired = false
            rotatedWhilePressed = false
            tapCount = 0
            return
        }

        // Rotation during the press consumed this gesture; also reset tapCount
        // so a later lone tap isn't misread as a double tap (mute/sleep!)
        guard !rotatedWhilePressed else {
            buttonDownTime = nil
            rotatedWhilePressed = false
            tapCount = 0
            return
        }

        registerTap()

        buttonDownTime = nil
        longPressFired = false
    }

    /// Counts one finished tap; a second one inside `doubleTapInterval` makes a double tap.
    private func registerTap() {
        tapCount += 1

        if tapCount >= 2 {
            // Double tap detected
            tapCount = 0
            singleTapTimer?.invalidate()
            singleTapTimer = nil
            delegate?.powerMateButtonDoubleTapped()
        } else {
            // First tap — wait for possible second tap (.common mode so the
            // timer survives while a menu's event-tracking loop is open)
            singleTapTimer?.invalidate()
            singleTapTimer = Timer(timeInterval: doubleTapInterval, target: self, selector: #selector(handleSingleTapTimeout(_:)), userInfo: nil, repeats: false)
            RunLoop.main.add(singleTapTimer!, forMode: .common)
        }
    }

    private func fireLongPress() {
        tapCount = 0
        singleTapTimer?.invalidate()
        singleTapTimer = nil
        delegate?.powerMateButtonLongPressed()
    }

    // Timer actions (selector-based so they run in .common run-loop mode)

    @objc private func handleLongPress(_ timer: Timer) {
        longPressFired = true
        fireLongPress()
    }

    @objc private func handleSingleTapTimeout(_ timer: Timer) {
        tapCount = 0
        delegate?.powerMateButtonPressed()
    }

    private func resetGestureState() {
        singleTapTimer?.invalidate()
        singleTapTimer = nil
        longPressTimer?.invalidate()
        longPressTimer = nil
        buttonDownTime = nil
        longPressFired = false
        tapCount = 0
        lastButtonState = false
        rotatedWhilePressed = false
    }
}
