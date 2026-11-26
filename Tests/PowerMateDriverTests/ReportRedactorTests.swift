import XCTest
@testable import PowerMateDriver

/// Reports are posted on a public issue tracker. The app's logs and system
/// information can carry the reporter's account name, home folder and, in
/// device names like "Dana's AirPods", their own name.
final class ReportRedactorTests: XCTestCase {
    private let redactor = ReportRedactor(homeDirectory: "/Users/dmiller",
                                          userName: "dmiller",
                                          fullName: "Dana Miller")

    func testTheHomeFolderBecomesATilde() {
        XCTAssertEqual(redactor.redact("Custom: failed to save profiles: /Users/dmiller/Library/x.json is locked"),
                       "Custom: failed to save profiles: ~/Library/x.json is locked")
    }

    func testAnotherFolderThatStartsLikeTheHomeFolderIsLeftAlone() {
        XCTAssertEqual(redactor.redact("open /Users/dmillerson/file"), "open /Users/dmillerson/file")
    }

    func testTheAccountNameIsRemovedWhereverItStandsAlone() {
        XCTAssertEqual(redactor.redact("owner dmiller, path /Volumes/Data/home/dmiller/x"),
                       "owner <user>, path /Volumes/Data/home/<user>/x")
    }

    func testTheReportersOwnNameIsRemovedFromDeviceNames() {
        XCTAssertEqual(redactor.redact("  Device 71: \"Dana’s AirPods Pro\" Bluetooth vol=[ok]"),
                       "  Device 71: \"<name>’s AirPods Pro\" Bluetooth vol=[ok]")
        XCTAssertEqual(redactor.redact("Volume: 40% via Dana Miller's iPhone Microphone"),
                       "Volume: 40% via <name> <name>'s iPhone Microphone")
    }

    // Names are matched as whole words, in the capitals the account uses, so
    // ordinary log text that happens to contain one is not damaged.
    func testWordsThatOnlyContainANameAreLeftAlone() {
        let art = ReportRedactor(homeDirectory: "/Users/art", userName: "art", fullName: "Art Will")
        let line = "Custom: actions will do nothing; Artwork restarted; smart mode"
        XCTAssertEqual(art.redact(line), line)
    }

    func testTextWithNothingPersonalIsUnchanged() {
        let line = "2026-11-13 10:21:41.701 PowerMateReborn[5206:37981] BLE: Knob 68 = rotate(1)"
        XCTAssertEqual(redactor.redact(line), line)
    }

    func testAnAccountWithNoNamesChangesNothing() {
        let nobody = ReportRedactor(homeDirectory: "", userName: "", fullName: "")
        XCTAssertEqual(nobody.redact("a / b  c"), "a / b  c")
        let root = ReportRedactor(homeDirectory: "/", userName: "", fullName: " ")
        XCTAssertEqual(root.redact("/Library/Audio/x"), "/Library/Audio/x")
    }

    func testANameWithPunctuationIsStillRemoved() {
        let odd = ReportRedactor(homeDirectory: "/Users/j", userName: "j.o'neil", fullName: "Jean-Luc O'Neil Jr.")
        XCTAssertEqual(odd.redact("Jean-Luc’s Mac (j.o'neil) O'Neil Jr"), "<name>’s Mac (<user>) <name> <name>")
    }
}
