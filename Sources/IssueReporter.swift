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
    static func recentLogTail(maxBytes: Int = 8192) -> String {
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

// MARK: - Issue Reporter

enum IssueReporter {
    static let repositoryURL = URL(string: "https://github.com/EricBintner/PowerMateReborn")!

    /// Markdown body for the GitHub issue.
    static func buildReportBody(description: String, includeLogs: Bool, logTail: String) -> String {
        var lines: [String] = []
        lines.append("### Description")
        lines.append(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "_(No description provided.)_"
                     : description)
        lines.append("")
        lines.append("### System Information")
        lines.append("```")
        lines.append(AppDelegate.shared?.systemInfoForReport() ?? "(unavailable)")
        lines.append("```")
        if includeLogs {
            lines.append("")
            lines.append("### Recent App Logs")
            lines.append("<details>")
            lines.append("<summary>stderr tail since launch</summary>")
            lines.append("")
            lines.append("```")
            lines.append(logTail.isEmpty ? "(no logs captured)" : logTail)
            lines.append("```")
            lines.append("")
            lines.append("</details>")
        }
        return lines.joined(separator: "\n")
    }

    /// Prefills the GitHub new-issue form via query params (title + body).
    /// Logs never go in the URL: GitHub answers "Malformed request" (HTTP 400)
    /// once a prefilled body holds enough log-style text — about 4,200
    /// characters, far below its URL length limit — so the caller copies the
    /// full report to the clipboard and the body asks for it to be pasted.
    static func githubIssueURL(title: String, description: String, includeLogs: Bool) -> URL? {
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        var limit = description.count
        while true {
            let desc = limit < description.count
                ? String(description.prefix(limit)) + "\n\n…(truncated — the full report is on your clipboard)"
                : description
            var body = buildReportBody(description: desc, includeLogs: false, logTail: "")
            if includeLogs {
                body += "\n\n### Recent App Logs\n_PowerMateReborn copied the full report, including recent logs, to your clipboard. Paste it here._"
            }
            guard let url = makeURL(title: cleanTitle, body: body) else { return nil }
            if url.absoluteString.count <= 3500 || limit <= 200 { return url }
            limit = limit * 3 / 4
        }
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
    @State private var includeLogs: Bool = true
    @State private var systemInfo: String = ""
    @State private var logTail: String = ""
    @State private var copiedFeedback: String?

    private var effectiveTitle: String {
        let trimmed = issueTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "PowerMateReborn \(version) issue"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Describe the problem — we'll open a GitHub issue with your system info filled in, and copy the full report with recent logs to your clipboard.")
                .font(.callout)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.headline)
                TextField("Short summary", text: $issueTitle)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(.headline)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $issueDescription)
                        .font(.system(size: 12))
                        .frame(minHeight: 90)
                    if issueDescription.isEmpty {
                        Text("What happened? What did you expect?")
                            .foregroundColor(Color(nsColor: .placeholderTextColor))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("System Information").font(.headline)
                infoBox(systemInfo.isEmpty ? "(collecting…)" : systemInfo, height: 128)
            }

            Toggle(isOn: $includeLogs) {
                Text("Include recent app logs")
            }

            if includeLogs {
                VStack(alignment: .leading, spacing: 4) {
                    infoBox(logTail.isEmpty ? "(no logs captured)" : logTail, height: 150)
                    Text("Logs may contain names of your audio devices and apps. GitHub can't take logs in a link, so they go to your clipboard: paste them into the issue.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                if let feedback = copiedFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Copy Report") { copyReport() }
                Button("Open GitHub Issue") { openGitHubIssue() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
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
        systemInfo = AppDelegate.shared?.systemInfoForReport() ?? "(unavailable)"
        logTail = AppLogCapture.recentLogTail(maxBytes: 8192)
    }

    private func openGitHubIssue() {
        // The full report (with logs, and any description the URL had to trim)
        // goes to the clipboard first; the prefilled issue asks for it.
        copyReport(feedback: "Full report copied — paste it into the GitHub issue")
        let url = IssueReporter.githubIssueURL(title: effectiveTitle,
                                               description: issueDescription,
                                               includeLogs: includeLogs)
            ?? IssueReporter.repositoryURL.appendingPathComponent("issues/new")
        NSWorkspace.shared.open(url)
    }

    private func copyReport(feedback: String = "Report copied to clipboard") {
        let body = IssueReporter.buildReportBody(description: issueDescription,
                                                 includeLogs: includeLogs,
                                                 logTail: logTail)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(effectiveTitle + "\n\n" + body, forType: .string)
        copiedFeedback = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { copiedFeedback = nil }
    }
}