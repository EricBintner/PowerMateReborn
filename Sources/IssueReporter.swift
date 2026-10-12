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
    /// GitHub rejects very long URLs, so the log section is trimmed until it fits.
    static func githubIssueURL(title: String, description: String, includeLogs: Bool, logTail: String) -> URL? {
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        var logs = logTail
        var desc = description
        var lastURL: URL?
        for _ in 0..<24 {
            let body = buildReportBody(description: desc, includeLogs: includeLogs && !logs.isEmpty, logTail: logs)
            guard let url = makeURL(title: cleanTitle, body: body) else { return nil }
            lastURL = url
            if url.absoluteString.count <= 7800 { return url }
            // Too long for GitHub: shrink, logs first, then the description
            if logs.count > 500 {
                logs = String(logs.prefix(logs.count / 2))
            } else if !logs.isEmpty {
                logs = ""
            } else if desc.count > 500 {
                desc = String(desc.prefix(500)) + "\n…(truncated)"
            } else {
                break
            }
        }
        return lastURL
    }

    private static func makeURL(title: String, body: String) -> URL? {
        var components = URLComponents(url: repositoryURL.appendingPathComponent("issues/new"),
                                        resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body)
        ]
        return components?.url
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
            Text("Describe the problem — we'll open a GitHub issue with your system info and recent logs attached.")
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
                    Text("Logs may contain names of your audio devices and apps. Very long logs are trimmed to fit the GitHub page — use Copy Report for the full version.")
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
        let url = IssueReporter.githubIssueURL(title: effectiveTitle,
                                               description: issueDescription,
                                               includeLogs: includeLogs,
                                               logTail: logTail)
            ?? IssueReporter.repositoryURL.appendingPathComponent("issues/new")
        NSWorkspace.shared.open(url)
    }

    private func copyReport() {
        let body = IssueReporter.buildReportBody(description: issueDescription,
                                                 includeLogs: includeLogs,
                                                 logTail: logTail)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(effectiveTitle + "\n\n" + body, forType: .string)
        copiedFeedback = "Report copied to clipboard"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { copiedFeedback = nil }
    }
}