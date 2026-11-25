import Foundation
import IOKit.pwr_mgt

// MARK: - High-Level Delegate (consumed by AppDelegate)

protocol PowerMateDelegate: AnyObject {
    func powerMateDidConnect(identity: String, displayName: String)
    func powerMateDidDisconnect(identity: String)
    func powerMateDidRotate(delta: Int, identity: String)
    func powerMateButtonPressed(identity: String)       // single press
    func powerMateButtonDoubleTapped(identity: String)  // two presses within doubleTapInterval
    func powerMateButtonLongPressed(identity: String)   // hold >= longPressThreshold
    func powerMateButtonReleased(identity: String)      // raw button-up (for extended press / sustain)
}

// MARK: - Transport Protocol

/// Events from a hardware transport (USB or BLE).
/// Transports report what the hardware says and leave gesture detection to
/// PowerMateManager. The USB knob reports raw button state. The Bluetooth
/// knob times presses in its own firmware and only reports finished clicks
/// and holds, so it uses the click and long-press calls instead.
/// `identity` names the physical knob (USB hub serial, hub container, Mac
/// port, or BLE peripheral).
protocol PowerMateTransportDelegate: AnyObject {
    func transportDidConnect(_ transport: PowerMateTransport, identity: String, displayName: String)
    func transportDidDisconnect(_ transport: PowerMateTransport, identity: String)
    func transport(_ transport: PowerMateTransport, identity: String, didRotate delta: Int)
    /// Raw button state (USB).
    func transport(_ transport: PowerMateTransport, identity: String, buttonStateChanged pressed: Bool)
    /// A finished short press, timed by the device (Bluetooth).
    func transportDidClick(_ transport: PowerMateTransport, identity: String)
    /// The device reports the button has been held long enough (Bluetooth).
    func transportDidLongPress(_ transport: PowerMateTransport, identity: String)
    /// The button was let go after `transportDidLongPress` (Bluetooth).
    func transportDidReleaseLongPress(_ transport: PowerMateTransport, identity: String)
}

/// A hardware transport that can communicate with one or more PowerMate devices.
protocol PowerMateTransport: AnyObject {
    var transportDelegate: PowerMateTransportDelegate? { get set }
    var isConnected: Bool { get }
    var connectedDevices: [(identity: String, displayName: String)] { get }
    func owns(_ identity: String) -> Bool
    func ledBrightness(for identity: String) -> UInt8
    func start()
    func stop()
    func setLEDBrightness(_ brightness: UInt8, identity: String)
}

// MARK: - PowerMateManager

/// Central manager that owns all transports (USB, BLE) and performs gesture
/// detection separately for each knob identity.
/// AppDelegate talks only to this class via `PowerMateDelegate`.
class PowerMateManager: NSObject, PowerMateTransportDelegate {
    weak var delegate: PowerMateDelegate?

    // Transports
    private var transports: [PowerMateTransport] = []

    private struct GestureState {
        var buttonDownTime: Date?
        var longPressTimer: Timer?
        var longPressFired: Bool = false
        var tapCount: Int = 0
        var singleTapTimer: Timer?
        var rotatedWhilePressed: Bool = false
        var lastButtonState: Bool = false
    }
    private var gestures: [String: GestureState] = [:]

    /// Press timing for one knob. The per-knob settings answer by default;
    /// tests replace it with short intervals.
    var gestureTiming: (String) -> (longPress: TimeInterval, doubleTap: TimeInterval) = { identity in
        let record = PowerMateDeviceStore.shared.record(for: identity)
        return (record.longPressThreshold, record.doubleTapInterval)
    }

    // Knob use counts as user activity, like a mouse: it wakes the displays
    // and postpones display sleep. macOS no longer sees the seized USB knob
    // (and never saw the BLE one), so declare it ourselves, at most once a second.
    private var userActivityAssertion = IOPMAssertionID(0)
    private var lastUserActivity = Date.distantPast

    // LED output reports block the main thread until the knob accepts them
    // (~8 ms, the USB interval). Keep one pending byte per knob and send it
    // at most 20 times a second, same shape as the volume throttle.
    private var pendingLED: [String: UInt8] = [:]
    private var lastLEDSent: [String: UInt8] = [:]
    private var lastLEDTime: [String: TimeInterval] = [:]
    private var ledTimers: [String: Timer] = [:]
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
        for timer in ledTimers.values { timer.invalidate() }
        ledTimers.removeAll()
        pendingLED.removeAll()
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

    func connectedDevices() -> [(identity: String, displayName: String)] {
        var seen = Set<String>()
        var result: [(identity: String, displayName: String)] = []
        for transport in transports {
            for device in transport.connectedDevices where seen.insert(device.identity).inserted {
                result.append(device)
            }
        }
        return result
    }

    // MARK: - LED Control

    func ledBrightness(for identity: String) -> UInt8 {
        transports.first { $0.owns(identity) }?.ledBrightness(for: identity) ?? 0
    }

    func setLEDBrightness(_ brightness: UInt8, for identity: String) {
        setLEDBrightness(brightness, for: identity, immediate: false)
    }

    /// Quit and the mode-change flash need the byte on the wire now.
    /// A spin only needs the latest byte, at most once per `ledMinInterval`.
    private func setLEDBrightness(_ brightness: UInt8, for identity: String, immediate: Bool) {
        if !immediate, pendingLED[identity] == brightness { return }
        if pendingLED[identity] == nil, lastLEDSent[identity] == brightness { return }

        pendingLED[identity] = brightness
        let elapsed = ProcessInfo.processInfo.systemUptime - (lastLEDTime[identity] ?? 0)
        if immediate || elapsed >= ledMinInterval {
            flushLED(identity)
        } else {
            ledTimers[identity]?.invalidate()
            let remaining = ledMinInterval - elapsed
            let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
                self?.flushLED(identity)
            }
            ledTimers[identity] = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func flushLED(_ identity: String) {
        ledTimers[identity]?.invalidate()
        ledTimers[identity] = nil
        guard let brightness = pendingLED.removeValue(forKey: identity) else { return }
        lastLEDTime[identity] = ProcessInfo.processInfo.systemUptime
        lastLEDSent[identity] = brightness
        for transport in transports where transport.owns(identity) {
            transport.setLEDBrightness(brightness, identity: identity)
        }
    }

    func setAllLEDBrightness(_ brightness: UInt8) {
        for device in connectedDevices() {
            setLEDBrightness(brightness, for: device.identity, immediate: true)
        }
    }

    // MARK: - PowerMateTransportDelegate

    func transportDidConnect(_ transport: PowerMateTransport, identity: String, displayName: String) {
        delegate?.powerMateDidConnect(identity: identity, displayName: displayName)
    }

    func transportDidDisconnect(_ transport: PowerMateTransport, identity: String) {
        // Another session (second knob on the same hub) may still own this identity.
        let stillPresent = transports.contains { $0.owns(identity) }
        if !stillPresent {
            resetGestureState(identity)
        }
        if !stillPresent {
            delegate?.powerMateDidDisconnect(identity: identity)
        }
    }

    func transport(_ transport: PowerMateTransport, identity: String, didRotate delta: Int) {
        declareUserActivity()
        updateGesture(identity) { state in
            if state.buttonDownTime != nil {
                state.rotatedWhilePressed = true
                // A press-rotate is not a long press: cancel the pending long-press
                // timer so it doesn't fire (mode switch) mid-adjustment.
                state.longPressTimer?.invalidate()
                state.longPressTimer = nil
            }
        }
        delegate?.powerMateDidRotate(delta: delta, identity: identity)
    }

    func transport(_ transport: PowerMateTransport, identity: String, buttonStateChanged pressed: Bool) {
        var ignore = false
        updateGesture(identity) { state in
            if pressed == state.lastButtonState {
                ignore = true
            } else {
                state.lastButtonState = pressed
            }
        }
        guard !ignore else { return }
        // Before gesture handling: a double tap ends here by sleeping the
        // displays, and that must come after this activity, not before it.
        declareUserActivity()
        if pressed {
            onButtonDown(identity)
        } else {
            onButtonUp(identity)
        }
    }

    func transportDidClick(_ transport: PowerMateTransport, identity: String) {
        declareUserActivity()
        registerTap(identity)
    }

    func transportDidLongPress(_ transport: PowerMateTransport, identity: String) {
        declareUserActivity()
        fireLongPress(identity)
    }

    func transportDidReleaseLongPress(_ transport: PowerMateTransport, identity: String) {
        delegate?.powerMateButtonReleased(identity: identity)
    }

    private func declareUserActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastUserActivity) >= 1.0 else { return }
        lastUserActivity = now
        IOPMAssertionDeclareUserActivity("PowerMate knob" as CFString, kIOPMUserActiveLocal, &userActivityAssertion)
    }

    // MARK: - Gesture Detection

    private func onButtonDown(_ identity: String) {
        let longPressThreshold = gestureTiming(identity).longPress
        updateGesture(identity) { state in
            state.buttonDownTime = Date()
            state.longPressFired = false
            state.rotatedWhilePressed = false

            state.singleTapTimer?.invalidate()
            state.singleTapTimer = nil

            state.longPressTimer?.invalidate()
            let timer = Timer(timeInterval: longPressThreshold, target: self, selector: #selector(handleLongPress(_:)), userInfo: identity, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            state.longPressTimer = timer
        }
    }

    private func onButtonUp(_ identity: String) {
        var longPressFired = false
        var rotatedWhilePressed = false
        updateGesture(identity) { state in
            state.longPressTimer?.invalidate()
            state.longPressTimer = nil
            longPressFired = state.longPressFired
            rotatedWhilePressed = state.rotatedWhilePressed
            state.buttonDownTime = nil
            state.longPressFired = false
            // A long press, or a rotation during the press, consumed this
            // gesture. Reset tapCount too, so a later lone tap isn't misread
            // as a double tap (mute/sleep!)
            if longPressFired || rotatedWhilePressed {
                state.rotatedWhilePressed = false
                state.tapCount = 0
            }
        }

        // Always notify raw release (for extended press / sustain actions)
        delegate?.powerMateButtonReleased(identity: identity)

        if longPressFired || rotatedWhilePressed { return }

        registerTap(identity)
    }

    /// Counts one finished tap; a second one inside `doubleTapInterval` makes a double tap.
    private func registerTap(_ identity: String) {
        var tapCount = 0
        updateGesture(identity) { state in
            state.tapCount += 1
            tapCount = state.tapCount
        }

        if tapCount >= 2 {
            updateGesture(identity) { state in
                state.tapCount = 0
                state.singleTapTimer?.invalidate()
                state.singleTapTimer = nil
            }
            delegate?.powerMateButtonDoubleTapped(identity: identity)
        } else {
            // First tap: wait for a possible second one (.common mode so the
            // timer survives while a menu's event-tracking loop is open)
            let interval = gestureTiming(identity).doubleTap
            updateGesture(identity) { state in
                state.singleTapTimer?.invalidate()
                let timer = Timer(timeInterval: interval, target: self, selector: #selector(handleSingleTapTimeout(_:)), userInfo: identity, repeats: false)
                RunLoop.main.add(timer, forMode: .common)
                state.singleTapTimer = timer
            }
        }
    }

    private func fireLongPress(_ identity: String) {
        updateGesture(identity) { state in
            state.tapCount = 0
            state.singleTapTimer?.invalidate()
            state.singleTapTimer = nil
        }
        delegate?.powerMateButtonLongPressed(identity: identity)
    }

    // Timer actions (selector-based so they run in .common run-loop mode)

    @objc private func handleLongPress(_ timer: Timer) {
        guard let identity = timer.userInfo as? String else { return }
        updateGesture(identity) { state in
            state.longPressFired = true
        }
        fireLongPress(identity)
    }

    @objc private func handleSingleTapTimeout(_ timer: Timer) {
        guard let identity = timer.userInfo as? String else { return }
        updateGesture(identity) { state in
            state.tapCount = 0
        }
        delegate?.powerMateButtonPressed(identity: identity)
    }

    private func updateGesture(_ identity: String, _ body: (inout GestureState) -> Void) {
        var state = gestures[identity] ?? GestureState()
        body(&state)
        gestures[identity] = state
    }

    private func resetGestureState(_ identity: String) {
        updateGesture(identity) { state in
            state.singleTapTimer?.invalidate()
            state.singleTapTimer = nil
            state.longPressTimer?.invalidate()
            state.longPressTimer = nil
            state.buttonDownTime = nil
            state.longPressFired = false
            state.tapCount = 0
            state.lastButtonState = false
            state.rotatedWhilePressed = false
        }
        gestures[identity] = nil
        ledTimers[identity]?.invalidate()
        ledTimers[identity] = nil
        pendingLED[identity] = nil
        lastLEDSent[identity] = nil
        lastLEDTime[identity] = nil
    }
}
