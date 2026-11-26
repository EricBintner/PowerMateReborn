import AppKit
import SwiftUI

// MARK: - Log Capture

/// Captures the app's stderr (where every NSLog call writes) to a file in
/// Application Support so issue reports can include recent logs. NSLog also
/// keeps writing to the unified logging system, so Console.app is unaffected.
enum AppLogCapture {
    static var logFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("PowerMateReborn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("PowerMateReborn.log")
    }

    /// Call once, as early as possible at launch.
    static func start() {
        // Trim an oversized log left by earlier runs so the file stays bounded
        if let size = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int,
           size > 2_000_000 {
            try? FileManager.default.removeItem(at: logFileURL)
        }
        freopen(logFileURL.path, "a", stderr)
    }

    /// The last `maxBytes` bytes of the log, aligned to a line boundary.
    static func recentLogTail(maxBytes: Int) -> String {
        guard let handle = FileHandle(forReadingAtPath: logFileURL.path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return "" }
        let start: UInt64 = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return "" }
        // If we seeked into the middle of the file, drop the partial first line
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }
}

// MARK: - Redaction

/// Takes the reporter's account name, home folder and own name out of text
/// that is about to be posted on a public issue tracker. The name matters
/// because macOS puts it in device names ("Dana's AirPods"), which the app
/// logs and reports.
struct ReportRedactor {
    let homeDirectory: String
    let userName: String
    let fullName: String

    static var currentUser: ReportRedactor {
        return ReportRedactor(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                              userName: NSUserName(),
                              fullName: NSFullUserName())
    }

    private static let wordStart = #"(?<![\p{L}\p{N}_])"#
    private static let wordEnd = #"(?![\p{L}\p{N}_])"#

    func redact(_ text: String) -> String {
        var result = text

        // The home folder first, so "/Users/name/Library" reads "~/Library".
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if !home.isEmpty {
            result = Self.replace(NSRegularExpression.escapedPattern(for: home) + Self.wordEnd, in: result) { _ in "~" }
        }

        // Then the account name and each part of the person's name, wherever
        // they stand as a whole word, in the capitals the account uses.
        // Ordinary log words that merely contain one ("will", "Artwork") stay.
        let names = fullName.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 2 }
        let account = userName.count >= 3 ? [userName] : []
        // Longest first, so a whole name wins over a shorter one inside it.
        let words = Set(account + names).sorted { ($0.count, $0) > ($1.count, $1) }
        guard !words.isEmpty else { return result }
        let anyWord = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return Self.replace(Self.wordStart + "(?:" + anyWord + ")" + Self.wordEnd, in: result) {
            $0 == userName ? "<user>" : "<name>"
        }
    }

    private static func replace(_ pattern: String, in text: String, with replacement: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var position = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            result += replacement(source.substring(with: match.range))
            position = match.range.location + match.range.length
        }
        return result + source.substring(from: position)
    }
}

// MARK: - Issue Reporter

/// Builds what Report Issue... sends. Nothing here touches the app's state,
/// so all of it is unit-tested.
enum IssueReporter {
    static let repositoryURL = URL(string: "https://github.com/EricBintner/PowerMateReborn")!

    /// The longest new-issue link GitHub is trusted with. It answers
    /// "Malformed request" (HTTP 400) once a prefilled body holds enough
    /// log-style text, about 4,200 characters, far below its URL length limit.
    static let linkLimit = 3500

    /// How much of the log a report carries. The logs travel by clipboard, so
    /// the link limit does not apply; this stays well inside GitHub's limit of
    /// 65,536 characters for an issue body.
    static let logTailBytes = 32_768

    /// Which PowerMate the reporter has. The form asks, because a knob that
    /// will not connect cannot say what it is.
    enum Knob: String, CaseIterable {
        case usb = "USB"
        case bluetooth = "Bluetooth"
        case both = "USB and Bluetooth"

        /// The answer the form starts with: only what is connected right now.
        init?(usbConnected: Bool, bluetoothConnected: Bool) {
            switch (usbConnected, bluetoothConnected) {
            case (true, true): self = .both
            case (true, false): self = .usb
            case (false, true): self = .bluetooth
            case (false, false): return nil
            }
        }

        var shortName: String {
            return self == .both ? "Both" : rawValue
        }
    }

    enum Field: Equatable {
        case title, description, knob
    }

    /// Everything the reporter and the app put into one report.
    struct Draft {
        var title: String
        var description: String
        var knob: Knob?
        var systemInfo: String
        /// The log to send, or nil when the reporter chose to leave it out.
        var logTail: String?

        /// What a new GitHub issue still needs. v1.2.2 opened issues with a
        /// stock title and no description.
        var missing: [Field] {
            var missing: [Field] = []
            if IssueReporter.trimmed(title).isEmpty { missing.append(.title) }
            if IssueReporter.trimmed(description).isEmpty { missing.append(.description) }
            if knob == nil { missing.append(.knob) }
            return missing
        }
    }

    /// A prefilled new-issue link, and what the reporter has to paste into it.
    struct GitHubIssue {
        let url: URL
        /// Only what the link could not carry, or nil when it carries everything.
        let clipboard: String?
    }

    /// What to tell the reporter while a new issue cannot be opened yet.
    static func hint(forMissing missing: [Field]) -> String? {
        guard !missing.isEmpty else { return nil }
        var steps: [String] = []
        if missing.contains(.title) { steps.append("a title") }
        if missing.contains(.description) { steps.append("a description") }
        if !steps.isEmpty { steps[0] = "add " + steps[0] }
        if missing.contains(.knob) { steps.append("say which PowerMate you have") }
        let last = steps.removeLast()
        let list = steps.isEmpty ? last : steps.joined(separator: ", ") + " and " + last
        return "To open an issue, \(list)."
    }

    /// The state of each kind of knob, for the system information.
    static func knobLines(usbConnected: Bool, bluetooth: PowerMateBLEStatus?) -> [String] {
        var lines = ["USB knob: " + (usbConnected ? "connected" : "not connected")]
        if let bluetooth = bluetooth {
            lines.append("Bluetooth knob: " + bluetooth.summary)
        }
        return lines
    }

    /// The whole report, for Copy Report: pasted where nothing is filled in
    /// yet, such as a comment on an existing issue.
    static func fullReport(_ draft: Draft) -> String {
        let title = trimmed(draft.title)
        return join((title.isEmpty ? [] : [[title]]) + sections(of: draft, withLogs: true))
    }

    /// A new issue with the title, description and system information filled
    /// in, and the logs on the clipboard: GitHub rejects logs in a link.
    /// The clipboard never repeats what the link carries, so pasting it gives
    /// each part of the report once.
    static func githubIssue(_ draft: Draft) -> GitHubIssue {
        let title = String(trimmed(draft.title).prefix(100))

        var body = join(sections(of: draft, withLogs: false))
        var clipboard: String?
        if let log = draft.logTail {
            body += "\n\n" + logHeading
                + "\n_PowerMateReborn copied the recent logs to your clipboard. Paste them here (⌘V)._"
            clipboard = logBlock(log).joined(separator: "\n")
        }
        if let url = makeURL(title: title, body: body), url.absoluteString.count <= linkLimit {
            return GitHubIssue(url: url, clipboard: clipboard)
        }

        // Too long for a link. Cutting the description short would lose part
        // of it, so the link carries only the title and the whole report
        // goes to the clipboard instead.
        let note = "_PowerMateReborn copied the full report to your clipboard. Paste it here (⌘V), replacing this line._"
        let url = makeURL(title: title, body: note) ?? repositoryURL.appendingPathComponent("issues/new")
        return GitHubIssue(url: url, clipboard: join(sections(of: draft, withLogs: true)))
    }

    // MARK: Private

    private static let logHeading = "### Recent App Logs"

    private static func trimmed(_ text: String) -> String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func join(_ sections: [[String]]) -> String {
        return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    private static func sections(of draft: Draft, withLogs: Bool) -> [[String]] {
        var sections: [[String]] = []
        let description = trimmed(draft.description)
        if !description.isEmpty {
            sections.append(["### Description", description])
        }
        sections.append([
            "### System Information",
            "```",
            "Reporter's PowerMate: " + (draft.knob?.rawValue ?? "not stated"),
            draft.systemInfo,
            "```",
        ])
        if withLogs, let log = draft.logTail {
            sections.append([logHeading] + logBlock(log))
        }
        return sections
    }

    private static func logBlock(_ log: String) -> [String] {
        let log = trimmed(log)
        return [
            "<details>",
            "<summary>Recent app log</summary>",
            "",
            "```",
            log.isEmpty ? "(no logs captured)" : log,
            "```",
            "",
            "</details>",
        ]
    }

    private static func makeURL(title: String, body: String) -> URL? {
        guard var components = URLComponents(url: repositoryURL.appendingPathComponent("issues/new"),
                                              resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body)
        ]
        // URLComponents leaves "+" as-is, which GitHub decodes as a space
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = query
        return components.url
    }
}

// MARK: - Report Window UI

struct IssueReportView: View {
    @State private var issueTitle: String = ""
    @State private var issueDescription: String = ""
    @State private var knob: IssueReporter.Knob?
    @State private var includeLogs: Bool = true
    @State private var systemInfo: String = ""
    @State private var logTail: String = ""
    @State private var copiedFeedback: String?

    private var draft: IssueReporter.Draft {
        return IssueReporter.Draft(title: issueTitle,
                                   description: issueDescription,
                                   knob: knob,
                                   systemInfo: systemInfo,
                                   logTail: includeLogs ? logTail : nil)
    }

    // Layout note: do not put .fixedSize(horizontal: false, vertical: true)
    // on the texts here. The hosting window then works out an enormous
    // minimum height and opens thousands of points tall. The window is sized
    // to fit this form in AppDelegate.showIssueReporter().
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Describe the problem. This opens a GitHub issue with your system information filled in, and copies the recent logs to your clipboard for you to paste into it.")
                .font(.callout)
                .foregroundColor(.secondary)
                .layoutPriority(1)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.headline)
                TextField("Short summary", text: $issueTitle)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                Text("Which PowerMate do you have?").font(.headline)
                Picker("Which PowerMate do you have?", selection: $knob) {
                    ForEach(IssueReporter.Knob.allCases, id: \.self) { knob in
                        Text(knob.shortName).tag(Optional(knob))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(.headline)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $issueDescription)
                        .font(.system(size: 12))
                        .frame(minHeight: 90)
                    if issueDescription.isEmpty {
                        Text("What did you do, what happened, and what did you expect?")
                            .foregroundColor(Color(nsColor: .placeholderTextColor))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("System Information").font(.headline)
                infoBox(systemInfo.isEmpty ? "(collecting…)" : systemInfo, height: 112)
            }

            Toggle(isOn: $includeLogs) {
                Text("Include recent app logs")
            }

            if includeLogs {
                VStack(alignment: .leading, spacing: 4) {
                    infoBox(logTail.isEmpty ? "(no logs captured)" : logTail, height: 120)
                    // Two short lines: one long caption is cut off, not wrapped,
                    // when the window is at its smallest.
                    Group {
                        Text("Your account name, your own name and your home folder have been taken out.")
                        Text("Names of your audio devices, displays and apps can remain.")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                if let status = copiedFeedback ?? IssueReporter.hint(forMissing: draft.missing) {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Copy Report") { copyReport() }
                Button("Open GitHub Issue") { openGitHubIssue() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.missing.isEmpty)
            }
            .layoutPriority(1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refreshData)
    }

    // MARK: Private

    private func infoBox(_ content: String, height: CGFloat) -> some View {
        ScrollView {
            Text(content)
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .textSelection(.enabled)
        }
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
    }

    private func refreshData() {
        // Redacted before it is shown, so the reporter sees what will be sent.
        let redactor = ReportRedactor.currentUser
        systemInfo = redactor.redact(AppDelegate.shared?.systemInfoForReport() ?? "(unavailable)")
        logTail = redactor.redact(AppLogCapture.recentLogTail(maxBytes: IssueReporter.logTailBytes))
        if knob == nil {
            knob = AppDelegate.shared?.connectedKnobForReport()
        }
    }

    private func openGitHubIssue() {
        let issue = IssueReporter.githubIssue(draft)
        // Only what the link could not carry goes to the clipboard; if the
        // link carries everything, the clipboard is left alone.
        if let clipboard = issue.clipboard {
            copy(clipboard, feedback: "Copied. Paste it into the GitHub issue (⌘V).")
        }
        NSWorkspace.shared.open(issue.url)
    }

    private func copyReport() {
        copy(IssueReporter.fullReport(draft), feedback: "Report copied to clipboard")
    }

    private func copy(_ text: String, feedback: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedFeedback = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { copiedFeedback = nil }
    }
}
