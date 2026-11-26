import Foundation
import CoreBluetooth

// The Griffin PowerMate Bluetooth protocol, kept free of live Bluetooth
// objects so it can be unit-tested: nobody on this project owns the hardware.
//
// The byte values match a LightBlue capture from a user's knob (GitHub
// issue 4, firmware 1.0.1) and these independent implementations:
//   stefansundin/powermate-linux (bluetooth/powermate-poc.py)
//   prokrypt/ha-griffin-powermate and prokrypt/powuhmate
//   asmagill/hammerspoon_asm (btle/examples/powermate.lua)
//   albebaubles/powermate-btle-osx

/// GATT identifiers of the Griffin PowerMate Bluetooth.
enum PowerMateBLEUUID {
    static let service = CBUUID(string: "25598CF7-4240-40A6-9910-080F19F91EBC")
    /// All knob input: one event byte per notification (see `PowerMateBLEEvent`).
    static let knob = CBUUID(string: "9CF53570-DDD9-47F3-BA63-09ACEFC60415")
    /// Battery percentage. Notify only, and not the button.
    static let battery = CBUUID(string: "50F09CC9-FE1D-4C79-A962-B3A7CD3E5584")
    /// LED command byte (see `PowerMateBLELED`).
    static let led = CBUUID(string: "847D189E-86EE-4BD2-966F-800832B1259D")
    /// Readable and writable; purpose unknown.
    static let unknown = CBUUID(string: "C5CF8AE4-6988-409F-9EC4-F9DAA9147D15")

    static let deviceInfoService = CBUUID(string: "180A")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let modelNumber = CBUUID(string: "2A24")
}

/// One notification from the knob characteristic. The knob times presses
/// itself: there is no raw button-down, only finished gestures.
enum PowerMateBLEEvent: Equatable {
    /// 0x65: the button was pressed and let go before the first hold code.
    case click
    /// 0x66: the button was let go after at least one hold code.
    case holdReleased
    /// 0x67 (-1, counterclockwise) or 0x68 (+1, clockwise): one detent.
    case rotate(Int)
    /// 0x69 (-1) or 0x70 (+1): one detent with the button held down.
    case rotateWhilePressed(Int)
    /// 0x72-0x77: the button is still down. Step 1 arrives about a second in;
    /// sources disagree on whether later steps are 0.5 s or 1 s apart.
    case held(step: Int)
    case unknown(UInt8)

    init(byte: UInt8) {
        switch byte {
        case 0x65: self = .click
        case 0x66: self = .holdReleased
        case 0x67: self = .rotate(-1)
        case 0x68: self = .rotate(1)
        case 0x69: self = .rotateWhilePressed(-1)
        case 0x70: self = .rotateWhilePressed(1)
        case 0x72...0x77: self = .held(step: Int(byte) - 0x71)
        default: self = .unknown(byte)
        }
    }
}

/// Decides what a discovered service means for the connection.
enum PowerMateBLEDiscovery {
    enum Outcome: Equatable {
        /// The PowerMate service, with a knob characteristic we can subscribe to.
        case ready
        /// The PowerMate service, but no way to receive knob input.
        case unusable
        /// Some other service (Device Information). Never grounds to disconnect.
        case ignored
    }

    static func outcome(service: CBUUID,
                        characteristics: [(uuid: CBUUID, properties: CBCharacteristicProperties)]) -> Outcome {
        guard service == PowerMateBLEUUID.service else { return .ignored }
        let knobNotifies = characteristics.contains {
            $0.uuid == PowerMateBLEUUID.knob && $0.properties.contains(.notify)
        }
        return knobNotifies ? .ready : .unusable
    }
}

/// The LED takes a command byte, not a 0-255 level: 0x80 is off, 0xA1-0xBF
/// are steady levels from dim to bright, and 0xA0 and 0xC0 upward blink.
enum PowerMateBLELED {
    static let off: UInt8 = 0x80
    static let dimmest: UInt8 = 0xA1
    static let brightest: UInt8 = 0xBF

    /// Maps the app's 0-255 brightness onto the steady range.
    static func byte(forBrightness brightness: UInt8) -> UInt8 {
        guard brightness > 0 else { return off }
        let steps = Int(brightest - dimmest)
        return dimmest + UInt8(((Int(brightness) - 1) * steps + 127) / 254)
    }
}

/// What the transport reports to `PowerMateManager` for one knob event.
enum PowerMateBLEAction: Equatable {
    case rotate(Int)
    case click
    case longPress
    case longPressReleased
}

/// Turns the knob's event stream into gestures, dropping the extra events its
/// button is known to send. The quiet periods come from traces recorded on
/// real hardware by the Home Assistant and powuhmate projects.
struct PowerMateBLEGestureFilter {
    /// The button can send the same press twice. Until a user's log shows how
    /// far apart the two arrive, a second click this soon is treated as that
    /// repeat. Clicks therefore cannot form a double tap on Bluetooth yet.
    static let clickRepeatQuiet: TimeInterval = 1.0
    /// How long after the last sign of a pressed turn its press is taken to be
    /// still going. Letting go sends a stray click, seen a full second after
    /// the last step, and hold codes arrive at most a second apart.
    static let pressedTurnQuiet: TimeInterval = 1.5
    /// A hold release can be followed by a stray click.
    static let holdReleaseQuiet: TimeInterval = 1.0

    private var lastClick: TimeInterval?
    /// The last event known to belong to a press that included a turn: a
    /// pressed-turn step, or a hold code ignored because of one.
    private var pressedTurnSeen: TimeInterval?
    private var lastHoldRelease: TimeInterval?
    /// A long press has been reported and its release has not.
    private(set) var isLongPressActive = false

    /// The gestures one knob event stands for: usually one, sometimes none,
    /// and two when the event also shows that an open long press has ended.
    mutating func actions(for event: PowerMateBLEEvent, at now: TimeInterval) -> [PowerMateBLEAction] {
        switch event {
        case .rotate(let delta):
            // A plain turn only happens with the button up.
            return endLongPress(at: now) + [.rotate(delta)]

        case .rotateWhilePressed(let delta):
            pressedTurnSeen = now
            return [.rotate(delta)]

        case .click:
            // A click only happens with the button up. If a long press was
            // still open, this is how it ended, not a tap of its own.
            let released = endLongPress(at: now)
            guard released.isEmpty else { return released }
            if isWithin(Self.pressedTurnQuiet, of: pressedTurnSeen, at: now)
                || isWithin(Self.holdReleaseQuiet, of: lastHoldRelease, at: now)
                || isWithin(Self.clickRepeatQuiet, of: lastClick, at: now) {
                return []
            }
            lastClick = now
            return [.click]

        case .held:
            if isLongPressActive { return [] }
            // Pressing and turning is an adjustment, not a long press, for as
            // long as that press lasts: keep following it while its hold
            // codes keep coming.
            if isWithin(Self.pressedTurnQuiet, of: pressedTurnSeen, at: now) {
                pressedTurnSeen = now
                return []
            }
            isLongPressActive = true
            return [.longPress]

        case .holdReleased:
            // The button is up, so a press that included a turn is over.
            pressedTurnSeen = nil
            lastHoldRelease = now
            return endLongPress(at: now)

        case .unknown:
            return []
        }
    }

    /// Forget everything, for a new connection.
    mutating func reset() {
        self = PowerMateBLEGestureFilter()
    }

    /// Reports the release of an open long press, if there is one. Every
    /// long press must end: a sustained Custom-mode action stays on until it does.
    private mutating func endLongPress(at now: TimeInterval) -> [PowerMateBLEAction] {
        guard isLongPressActive else { return [] }
        isLongPressActive = false
        lastHoldRelease = now
        return [.longPressReleased]
    }

    private func isWithin(_ interval: TimeInterval, of earlier: TimeInterval?, at now: TimeInterval) -> Bool {
        guard let earlier = earlier else { return false }
        return now - earlier < interval
    }
}

/// How long to wait before looking for the knob again once a connection ends.
enum PowerMateBLEReconnect {
    /// A connection that stayed usable this long counts as stable.
    static let stableSession: TimeInterval = 30
    static let firstDelay: TimeInterval = 2
    static let maxDelay: TimeInterval = 300

    /// `count` is how many connections in a row failed, never became usable,
    /// or dropped before they were stable. The wait doubles with each one, so
    /// a connection that keeps failing cannot repeat every few seconds.
    static func delay(afterUnstableConnections count: Int) -> TimeInterval {
        guard count > 0 else { return firstDelay }
        return min(firstDelay * pow(2, Double(min(count, 16))), maxDelay)
    }
}

/// The Bluetooth knob this Mac last used, kept across launches so the app can
/// ask the system for that knob directly instead of relying on a scan.
/// Only a connection that became usable is remembered, so someone who has
/// never had a Bluetooth knob working has nothing here.
struct PowerMateBLEKnownKnob {
    static let defaultsKey = "powermate.ble.knownKnob"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// CoreBluetooth's identifier for the knob. It is specific to this Mac.
    var identifier: UUID? {
        return defaults.string(forKey: Self.defaultsKey).flatMap(UUID.init(uuidString:))
    }

    func remember(_ identifier: UUID) {
        defaults.set(identifier.uuidString, forKey: Self.defaultsKey)
    }

    func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// What the Bluetooth side is doing, for issue reports. A report from someone
/// whose knob will not connect is otherwise silent about Bluetooth.
struct PowerMateBLEStatus: Equatable {
    enum Radio: Equatable {
        case on
        case off
        /// The user has not let this app use Bluetooth.
        case notAllowed
        case unsupported
        /// Not started yet, starting up, or resetting.
        case notReady

        init(_ state: CBManagerState?) {
            switch state {
            case .poweredOn?: self = .on
            case .poweredOff?: self = .off
            case .unauthorized?: self = .notAllowed
            case .unsupported?: self = .unsupported
            default: self = .notReady
            }
        }
    }

    var radio: Radio
    var isConnected: Bool
    /// A knob has become usable on this Mac before (see `PowerMateBLEKnownKnob`).
    var remembersKnob: Bool
    /// Connections in a row that failed, never became usable, or dropped early.
    var unstableConnections: Int
    var firmware: String?
    var batteryPercent: Int?

    /// One line for the report, after "Bluetooth knob: ".
    var summary: String {
        if isConnected {
            var details: [String] = []
            if let firmware = firmware { details.append("firmware \(firmware)") }
            if let battery = batteryPercent { details.append("battery \(battery)%") }
            return details.isEmpty ? "connected" : "connected (\(details.joined(separator: ", ")))"
        }

        var facts: [String] = []
        switch radio {
        case .on: facts.append("Bluetooth is on")
        case .off: facts.append("Bluetooth is off")
        case .notAllowed: facts.append("PowerMateReborn is not allowed to use Bluetooth")
        case .unsupported: facts.append("this Mac has no Bluetooth LE")
        case .notReady: facts.append("Bluetooth is not ready")
        }
        facts.append(remembersKnob ? "a knob has worked on this Mac before" : "no knob has worked on this Mac yet")
        if unstableConnections == 1 {
            facts.append("the last connection failed or dropped early")
        } else if unstableConnections > 1 {
            facts.append("the last \(unstableConnections) connections failed or dropped early")
        }
        return "not connected (\(facts.joined(separator: "; ")))"
    }
}
