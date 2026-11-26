import XCTest
@testable import PowerMateDriver

/// The app remembers the Bluetooth knob it last used so it can ask the system
/// for that knob directly instead of relying on a scan to catch it.
final class PowerMateBLEKnownKnobTests: XCTestCase {
    private let suiteName = "PowerMateDriverTests.knownKnob"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // USB-only users have never connected a Bluetooth knob. With nothing
    // remembered, the app makes no standing connection request for them.
    func testNothingIsRememberedUntilAKnobHasWorked() {
        XCTAssertNil(PowerMateBLEKnownKnob(defaults: defaults).identifier)
    }

    func testARememberedKnobIsStillThereOnTheNextLaunch() {
        let knob = UUID()
        PowerMateBLEKnownKnob(defaults: defaults).remember(knob)
        XCTAssertEqual(PowerMateBLEKnownKnob(defaults: defaults).identifier, knob)
    }

    func testRememberingAnotherKnobReplacesTheFirst() {
        let store = PowerMateBLEKnownKnob(defaults: defaults)
        let second = UUID()
        store.remember(UUID())
        store.remember(second)
        XCTAssertEqual(store.identifier, second)
    }

    func testForgettingLeavesNothingRemembered() {
        let store = PowerMateBLEKnownKnob(defaults: defaults)
        store.remember(UUID())
        store.forget()
        XCTAssertNil(store.identifier)
    }

    func testAValueThatIsNotAnIdentifierCountsAsNothing() {
        defaults.set("not an identifier", forKey: PowerMateBLEKnownKnob.defaultsKey)
        XCTAssertNil(PowerMateBLEKnownKnob(defaults: defaults).identifier)
    }
}
