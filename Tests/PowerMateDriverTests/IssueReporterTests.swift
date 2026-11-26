import XCTest
@testable import PowerMateDriver

/// Reports from Report Issue... are the only evidence there is for the
/// Bluetooth knob, which the maintainer cannot test. The v1.2.2 reports
/// repeated their title, description and system information when the
/// clipboard was pasted, could be sent with no title or description, and did
/// not say which knob the reporter owned.
final class IssueReporterTests: XCTestCase {
    private let problem = "It never shows up in the menu."
    private let appLine = "App: PowerMateReborn 9.9.9 (99)"
    private let logLine = "BLE: Knob 68 = rotate(1)"

    private func draft(title: String = "Knob will not connect",
                       description: String? = nil,
                       knob: IssueReporter.Knob? = .bluetooth,
                       logTail: String? = "BLE: Scanning for PowerMate Bluetooth...\nBLE: Knob 68 = rotate(1)")
        -> IssueReporter.Draft {
        return IssueReporter.Draft(title: title,
                                   description: description ?? problem,
                                   knob: knob,
                                   systemInfo: appLine + "\nOS: macOS 15.1",
                                   logTail: logTail)
    }

    private func query(_ name: String, of url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first(where: { $0.name == name })?.value ?? ""
    }

    private func count(_ needle: String, in text: String) -> Int {
        return text.components(separatedBy: needle).count - 1
    }

    // MARK: Opening a GitHub issue

    func testOpeningAnIssuePrefillsTitleDescriptionAndSystemInformation() {
        let issue = IssueReporter.githubIssue(draft())
        XCTAssertTrue(issue.url.absoluteString.hasPrefix("https://github.com/EricBintner/PowerMateReborn/issues/new?"))
        XCTAssertEqual(query("title", of: issue.url), "Knob will not connect")
        let body = query("body", of: issue.url)
        XCTAssertEqual(count(problem, in: body), 1)
        XCTAssertEqual(count(appLine, in: body), 1)
    }

    // GitHub answers "Malformed request" when log text is put in the link.
    func testLogsGoToTheClipboardAndNeverIntoTheLink() {
        let issue = IssueReporter.githubIssue(draft())
        XCTAssertEqual(count(logLine, in: query("body", of: issue.url)), 0)
        XCTAssertEqual(count(logLine, in: issue.clipboard ?? ""), 1)
        XCTAssertTrue(query("body", of: issue.url).contains("clipboard"), "the issue must ask for the paste")
    }

    // The v1.2.2 bug: the clipboard held the whole report, so pasting it
    // into the prefilled issue repeated everything but the logs.
    func testPastingTheClipboardDoesNotRepeatWhatTheIssueAlreadyHolds() {
        let issue = IssueReporter.githubIssue(draft())
        let clipboard = issue.clipboard ?? ""
        XCTAssertEqual(count(problem, in: clipboard), 0)
        XCTAssertEqual(count(appLine, in: clipboard), 0)
        XCTAssertEqual(count("Knob will not connect", in: clipboard), 0)

        let pasted = query("body", of: issue.url) + "\n" + clipboard
        XCTAssertEqual(count(problem, in: pasted), 1)
        XCTAssertEqual(count(appLine, in: pasted), 1)
        XCTAssertEqual(count(logLine, in: pasted), 1)
    }

    func testNothingIsCopiedWhenTheIssueIsAlreadyComplete() {
        let issue = IssueReporter.githubIssue(draft(logTail: nil))
        XCTAssertNil(issue.clipboard, "the clipboard must be left alone when there is nothing to paste")
        let body = query("body", of: issue.url)
        XCTAssertEqual(count(problem, in: body), 1)
        XCTAssertFalse(body.contains("clipboard"), "nothing to paste, so nothing should ask for it")
    }

    func testADescriptionTooLongForTheLinkGoesToTheClipboardWhole() {
        let long = String(repeating: "The knob does nothing at all. ", count: 300) + "And that is the end."
        let issue = IssueReporter.githubIssue(draft(description: long))
        XCTAssertLessThanOrEqual(issue.url.absoluteString.count, IssueReporter.linkLimit)
        XCTAssertEqual(query("title", of: issue.url), "Knob will not connect")

        let body = query("body", of: issue.url)
        XCTAssertEqual(count("The knob does nothing", in: body), 0, "no part of a description that does not fit")
        XCTAssertEqual(count(appLine, in: body), 0)
        XCTAssertTrue(body.contains("clipboard"))

        let clipboard = issue.clipboard ?? ""
        XCTAssertEqual(count(long, in: clipboard), 1, "the whole description, once")
        XCTAssertEqual(count(appLine, in: clipboard), 1)
        XCTAssertEqual(count(logLine, in: clipboard), 1)
    }

    // Text that grows when percent-encoded must still give a link GitHub accepts.
    func testTheLinkStaysWithinTheLimitWhenTheDescriptionEncodesLong() {
        let long = String(repeating: "Lautstärke geht nicht — überhaupt nicht.\n", count: 40)
        let issue = IssueReporter.githubIssue(draft(description: long))
        XCTAssertLessThanOrEqual(issue.url.absoluteString.count, IssueReporter.linkLimit)
        let pasted = query("body", of: issue.url) + "\n" + (issue.clipboard ?? "")
        XCTAssertEqual(count(long.trimmingCharacters(in: .whitespacesAndNewlines), in: pasted), 1)
    }

    func testAPlusSignSurvivesTheLink() {
        let issue = IssueReporter.githubIssue(draft(title: "Volume + brightness", description: "1 + 1"))
        XCTAssertFalse(issue.url.absoluteString.contains("+"), "GitHub reads a bare + as a space")
        XCTAssertEqual(query("title", of: issue.url), "Volume + brightness")
        XCTAssertEqual(count("1 + 1", in: query("body", of: issue.url)), 1)
    }

    func testTheTitleIsTrimmedAndKeptToOneHundredCharacters() {
        let issue = IssueReporter.githubIssue(draft(title: "  " + String(repeating: "x", count: 150) + "  "))
        XCTAssertEqual(query("title", of: issue.url), String(repeating: "x", count: 100))
    }

    func testAnEmptyLogIsStatedRatherThanLeftBlank() {
        let issue = IssueReporter.githubIssue(draft(logTail: ""))
        XCTAssertTrue((issue.clipboard ?? "").contains("(no logs captured)"))
    }

    // MARK: Which knob

    // A knob that will not connect cannot say what it is; the reporter can.
    func testTheReportersKnobIsStatedWithTheSystemInformation() {
        let issue = IssueReporter.githubIssue(draft(knob: .bluetooth))
        XCTAssertEqual(count("Reporter's PowerMate: Bluetooth", in: query("body", of: issue.url)), 1)
        XCTAssertEqual(count("Reporter's PowerMate: USB", in: IssueReporter.fullReport(draft(knob: .usb))), 1)
        XCTAssertEqual(count("Reporter's PowerMate: USB and Bluetooth",
                             in: IssueReporter.fullReport(draft(knob: .both))), 1)
    }

    func testAnUnansweredKnobQuestionIsStatedAsSuch() {
        XCTAssertEqual(count("Reporter's PowerMate: not stated", in: IssueReporter.fullReport(draft(knob: nil))), 1)
    }

    // The form answers the question in advance only from what is connected
    // right now; with nothing connected the reporter has to say.
    func testTheKnobQuestionIsAnsweredInAdvanceOnlyByWhatIsConnected() {
        XCTAssertEqual(IssueReporter.Knob(usbConnected: true, bluetoothConnected: false), .usb)
        XCTAssertEqual(IssueReporter.Knob(usbConnected: false, bluetoothConnected: true), .bluetooth)
        XCTAssertEqual(IssueReporter.Knob(usbConnected: true, bluetoothConnected: true), .both)
        XCTAssertNil(IssueReporter.Knob(usbConnected: false, bluetoothConnected: false))
    }

    // MARK: What an issue needs

    func testABlankDraftLacksEverythingAnIssueNeeds() {
        let blank = IssueReporter.Draft(title: "", description: "", knob: nil, systemInfo: "", logTail: nil)
        XCTAssertEqual(blank.missing, [.title, .description, .knob])
    }

    func testSpacesAndNewlinesDoNotCountAsATitleOrDescription() {
        XCTAssertEqual(draft(title: "   ", description: " \n\t ").missing, [.title, .description])
    }

    func testACompleteDraftLacksNothing() {
        XCTAssertEqual(draft().missing, [])
    }

    func testTheHintNamesWhatIsStillNeeded() {
        XCTAssertNil(IssueReporter.hint(forMissing: []))
        XCTAssertEqual(IssueReporter.hint(forMissing: [.description]),
                       "To open an issue, add a description.")
        XCTAssertEqual(IssueReporter.hint(forMissing: [.title, .knob]),
                       "To open an issue, add a title and say which PowerMate you have.")
        XCTAssertEqual(IssueReporter.hint(forMissing: [.title, .description, .knob]),
                       "To open an issue, add a title, a description and say which PowerMate you have.")
    }

    // MARK: Copy Report

    // Copy Report is for pasting somewhere that has nothing yet, such as a
    // comment on an existing issue, so it holds everything.
    func testCopyReportHoldsEverythingOnce() {
        let report = IssueReporter.fullReport(draft())
        XCTAssertEqual(count("Knob will not connect", in: report), 1)
        XCTAssertEqual(count(problem, in: report), 1)
        XCTAssertEqual(count(appLine, in: report), 1)
        XCTAssertEqual(count(logLine, in: report), 1)
    }

    func testCopyReportLeavesOutABlankTitleAndDescription() {
        let report = IssueReporter.fullReport(draft(title: "  ", description: "\n"))
        XCTAssertTrue(report.hasPrefix("### System Information"), "got: \(report.prefix(60))")
        XCTAssertFalse(report.contains("Description"))
        XCTAssertEqual(count(logLine, in: report), 1)
    }

    func testCopyReportWithoutLogsHasNoLogSection() {
        let report = IssueReporter.fullReport(draft(logTail: nil))
        XCTAssertFalse(report.contains("Recent App Logs"))
        XCTAssertEqual(count(appLine, in: report), 1)
    }

    // MARK: Knob status lines

    private func bluetooth(radio: PowerMateBLEStatus.Radio = .on, isConnected: Bool = false,
                           remembersKnob: Bool = false) -> PowerMateBLEStatus {
        return PowerMateBLEStatus(radio: radio, isConnected: isConnected, remembersKnob: remembersKnob,
                                  unstableConnections: 0, firmware: nil, batteryPercent: nil)
    }

    // v1.2.2 said only "Device: PowerMate Disconnected".
    func testADisconnectedReportSaysWhatEachKindOfKnobIsDoing() {
        XCTAssertEqual(IssueReporter.knobLines(usbConnected: false, bluetooth: bluetooth()), [
            "USB knob: not connected",
            "Bluetooth knob: not connected (Bluetooth is on; no knob has worked on this Mac yet)",
        ])
    }

    func testAConnectedUSBKnobIsReportedBesideTheBluetoothState() {
        XCTAssertEqual(IssueReporter.knobLines(usbConnected: true, bluetooth: bluetooth(radio: .off)), [
            "USB knob: connected",
            "Bluetooth knob: not connected (Bluetooth is off; no knob has worked on this Mac yet)",
        ])
    }

    func testWithoutABluetoothTransportOnlyTheUSBKnobIsReported() {
        XCTAssertEqual(IssueReporter.knobLines(usbConnected: true, bluetooth: nil), ["USB knob: connected"])
    }
}
