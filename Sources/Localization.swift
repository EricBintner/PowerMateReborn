import Foundation

/// The app's interface text. The English text is the key; each language adds a
/// `<language>.lproj/Localizable.strings` file in Sources/Resources that maps
/// it to a translation (fi today). A language without a file shows English, so
/// a missing translation costs a sentence, never the app.
///
/// What goes to GitHub in an issue report (system information, headings,
/// recent logs) stays English on purpose: the people reading it need one
/// language. Only what the reporter sees in the form is translated.
enum Localization {
    /// Marks "this folder has no entry"; no real string equals it.
    private static let missing = "\u{1}missing"

    /// The translation of `key` from the first language folder that has one,
    /// or `key`. See `languageFolders`.
    static func string(_ key: String, in folders: [Bundle]) -> String {
        for folder in folders {
            let value = folder.localizedString(forKey: key, value: missing, table: nil)
            if value != missing { return value }
        }
        return key
    }

    /// The bundles that can hold the app's strings, best first. The packaged
    /// app keeps its `.lproj` folders in Contents/Resources; `swift run` keeps
    /// them in SwiftPM's resource bundle (see AppResources).
    static func bundles(mainBundle: Bundle = .main) -> [Bundle] {
        var bundles = [mainBundle]
        if let swiftPM = AppResources.swiftPMBundle(mainBundle: mainBundle) {
            bundles.append(swiftPM)
        }
        return bundles
    }

    /// Each bundle's `.lproj` folder for the user's language, where it has one.
    ///
    /// The language is chosen here, from the user's list, because macOS picks
    /// the app's language from the *main* bundle only. Under `swift run` that
    /// bundle holds no translations, so the choice would always be English and
    /// SwiftPM's bundle beside it would never be asked for Finnish.
    static func languageFolders(in bundles: [Bundle], preferredLanguages: [String]) -> [Bundle] {
        return bundles.compactMap { bundle in
            let languages = Bundle.preferredLocalizations(from: bundle.localizations,
                                                          forPreferences: preferredLanguages)
            for language in languages {
                if let path = bundle.path(forResource: language, ofType: "lproj"),
                   let folder = Bundle(path: path) {
                    return folder
                }
            }
            return nil
        }
    }

    private static let appFolders = languageFolders(in: bundles(), preferredLanguages: Locale.preferredLanguages)

    static func string(_ key: String) -> String {
        return string(key, in: appFolders)
    }
}

/// Interface text in the user's language.
func tr(_ key: String) -> String {
    return Localization.string(key)
}

/// Interface text with values in it. `%@`, `%d` and `%.1f` stand for the
/// values; a translation that needs another order writes `%2$@ ... %1$@`.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    return String(format: Localization.string(key), locale: Locale.current, arguments: arguments)
}
