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
        for transport in transports {
            transport.stop()
        }
    }

    var isConnected: Bool {
        return transports.contains(where: { $0.isConnected })
    }

    /// Name of the transport currently connected to the device, if any (for issue reports).
    func activeTransportName() -> String? {
        return transports.first(where: { $0.isConnected }).map { type(of: $0) == PowerMateBLETransport.self ? "Bluetooth" : "USB" }
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

        buttonDownTime = nil
        longPressFired = false
    }

    // Timer actions (selector-based so they run in .common run-loop mode)

    @objc private func handleLongPress(_ timer: Timer) {
        longPressFired = true
        tapCount = 0
        singleTapTimer?.invalidate()
        singleTapTimer = nil
        delegate?.powerMateButtonLongPressed()
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
