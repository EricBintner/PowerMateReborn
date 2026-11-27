import XCTest
@testable import PowerMateDriver

/// The interface is English in the code and Finnish in
/// Sources/Resources/fi.lproj. A sentence added in code without a translation,
/// or a translation that lost a `%@`, would only show on a Finnish Mac, so the
/// tests read the code and the translation file and hold them together.
final class LocalizationTests: XCTestCase {
    private let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    private var finnishFolder: URL { sources.appendingPathComponent("Resources/fi.lproj", isDirectory: true) }

    private func finnish(_ table: String) throws -> [String: String] {
        let url = finnishFolder.appendingPathComponent("\(table).strings")
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String],
                                       "\(table).strings is not a valid strings file")
        return dictionary
    }

    /// Every `tr("…")` the code asks for, as the text the strings file spells.
    private func keysInCode() throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"\btr\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                // Swift and .strings spell quotes and backslashes alike.
                keys.insert(String(text[range]).replacingOccurrences(of: "\\\"", with: "\"")
                                               .replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return keys
    }

    private func placeholders(_ text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l)?[@dfs]"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map {
                String(text[$0]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
            }
        }.sorted()
    }

    func testEveryTextTheCodeAsksForHasAFinnishTranslation() throws {
        let translated = Set(try finnish("Localizable").keys)
        let missing = try keysInCode().subtracting(translated).sorted()
        XCTAssertTrue(missing.isEmpty, "No Finnish translation for: \(missing)")
    }

    func testFinnishFileHoldsNothingTheCodeNoLongerAsksFor() throws {
        let unused = Set(try finnish("Localizable").keys).subtracting(try keysInCode()).sorted()
        XCTAssertTrue(unused.isEmpty, "Finnish text no code asks for: \(unused)")
    }

    func testTranslationsAreFilledInAndKeepTheirPlaceholders() throws {
        for (key, value) in try finnish("Localizable") {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "Empty translation of \(key)")
            XCTAssertEqual(try placeholders(value), try placeholders(key), "Placeholders differ in \(key)")
        }
    }

    func testPermissionPromptsHaveFinnishText() throws {
        let prompts = try finnish("InfoPlist")
        for key in ["NSBluetoothAlwaysUsageDescription", "NSAppleEventsUsageDescription"] {
            XCTAssertFalse((prompts[key] ?? "").isEmpty, "No Finnish text for \(key)")
        }
    }

    func testFinnishFileAnswersThroughTheLookup() throws {
        let fi = try XCTUnwrap(Bundle(path: finnishFolder.path))
        XCTAssertEqual(Localization.string("Mute", in: [fi]), "Mykistä")
        XCTAssertEqual(Localization.string("Not a sentence anyone translated", in: [fi]),
                       "Not a sentence anyone translated")
    }

    // MARK: Where the lookup looks

    /// A bundle laid out the way the app is: one `.lproj` folder per language.
    private func bundle(named name: String, holding languages: [String: [String: String]]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalizationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("\(name).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents", isDirectory: true),
                                                withIntermediateDirectories: true)
        for (language, strings) in languages {
            let folder = app.appendingPathComponent("Contents/Resources/\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = strings.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
            try text.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.\(name)", "CFBundleDevelopmentRegion": "en"],
            format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(Bundle(url: app))
    }

    private func lookup(_ key: String, in bundles: [Bundle], languages: [String]) -> String {
        return Localization.string(key, in: Localization.languageFolders(in: bundles, preferredLanguages: languages))
    }

    func testTheUsersLanguageDecidesWhichFolderAnswers() throws {
        let app = try bundle(named: "App", holding: ["fi": ["Mute": "Mykistä"], "sv": ["Mute": "Tysta"]])
        XCTAssertEqual(lookup("Mute", in: [app], languages: ["fi-FI", "en"]), "Mykistä")
        XCTAssertEqual(lookup("Mute", in: [app], languages: ["sv", "fi"]), "Tysta")
        XCTAssertEqual(lookup("Mute", in: [app], languages: ["de-DE", "fi"]), "Mykistä")
    }

    /// A language the app has no folder for, and English itself, show the key.
    func testALanguageWithoutTranslationsShowsEnglish() throws {
        let app = try bundle(named: "App", holding: ["fi": ["Mute": "Mykistä"]])
        XCTAssertEqual(lookup("Mute", in: [app], languages: ["de-DE", "en"]), "Mute")
        XCTAssertEqual(lookup("Mute", in: [app], languages: ["en-FI"]), "Mute")
    }

    /// `swift run` keeps the translations in SwiftPM's bundle; its main bundle
    /// has none, and still has to hand over to the next bundle.
    func testLookupMovesOnToTheNextBundleAndThenToTheKey() throws {
        let main = try bundle(named: "Main", holding: [:])
        let swiftPM = try bundle(named: "SwiftPM", holding: ["fi": ["Mute": "Mykistä"]])
        XCTAssertEqual(lookup("Mute", in: [main, swiftPM], languages: ["fi"]), "Mykistä")
        XCTAssertEqual(lookup("Quit", in: [main, swiftPM], languages: ["fi"]), "Quit")
    }

    func testTheFirstBundleWithATranslationWins() throws {
        let main = try bundle(named: "Main", holding: ["fi": ["Mute": "from main"]])
        let swiftPM = try bundle(named: "SwiftPM", holding: ["fi": ["Mute": "from swiftpm", "Unmute": "only swiftpm"]])
        XCTAssertEqual(lookup("Mute", in: [main, swiftPM], languages: ["fi"]), "from main")
        XCTAssertEqual(lookup("Unmute", in: [main, swiftPM], languages: ["fi"]), "only swiftpm")
    }

    func testFormattedTextFillsInItsValues() {
        XCTAssertEqual(tr("Ch %d", 3), "Ch 3")
        XCTAssertEqual(tr("%@ and %@", "a", "b"), "a and b")
    }
}
