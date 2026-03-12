import Foundation

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

/// Raw events from a hardware transport (USB or BLE).
/// Transports should NOT perform gesture detection — just report raw hardware state.
protocol PowerMateTransportDelegate: AnyObject {
    func transportDidConnect(_ transport: PowerMateTransport)
    func transportDidDisconnect(_ transport: PowerMateTransport)
    func transport(_ transport: PowerMateTransport, didRotate delta: Int)
    func transport(_ transport: PowerMateTransport, buttonStateChanged pressed: Bool)
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
class PowerMateManager: PowerMateTransportDelegate {
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

    init() {}

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
        for transport in transports {
            transport.stop()
        }
    }

    var isConnected: Bool {
        return transports.contains(where: { $0.isConnected })
    }

    // MARK: - LED Control

    func setLEDBrightness(_ brightness: UInt8) {
        ledBrightness = brightness
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
        if buttonDownTime != nil {
            rotatedWhilePressed = true
        }
        delegate?.powerMateDidRotate(delta: delta)
    }

    func transport(_ transport: PowerMateTransport, buttonStateChanged pressed: Bool) {
        guard pressed != lastButtonState else { return }
        lastButtonState = pressed
        if pressed {
            onButtonDown()
        } else {
            onButtonUp()
        }
    }

    // MARK: - Gesture Detection

    private func onButtonDown() {
        buttonDownTime = Date()
        longPressFired = false
        rotatedWhilePressed = false

        // Cancel pending single-tap timer (we got another press)
        singleTapTimer?.invalidate()
        singleTapTimer = nil

        // Start long-press timer
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressThreshold, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.longPressFired = true
            self.tapCount = 0
            self.singleTapTimer?.invalidate()
            self.singleTapTimer = nil
            self.delegate?.powerMateButtonLongPressed()
        }
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
            return
        }

        guard !rotatedWhilePressed else {
            buttonDownTime = nil
            rotatedWhilePressed = false
            return
        }

        tapCount += 1

        if tapCount >= 2 {
            // Double tap detected
            tapCount = 0
            singleTapTimer?.invalidate()
            singleTapTimer = nil
            delegate?.powerMateButtonDoubleTapped()
        } else {
            // First tap — wait for possible second tap
            singleTapTimer?.invalidate()
            singleTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapInterval, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.tapCount = 0
                self.delegate?.powerMateButtonPressed()
            }
        }

        buttonDownTime = nil
        longPressFired = false
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
