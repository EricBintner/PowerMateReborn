import Foundation

/// Finds the app's bundled images without `Bundle.module`.
///
/// `Bundle.module` stops the app with "could not load resource bundle" when
/// SwiftPM's resource bundle is missing. scripts/build-dmg.sh does not package
/// that bundle (it copies the images into Contents/Resources), and the
/// accessor's only fallback is the build directory on the machine that
/// compiled the app. So `Bundle.module` works there and crashes everywhere
/// else, which is how About and Quick Start crashed in v1.2.2. A missing
/// image should cost a picture, never the app, so this returns nil instead.
enum AppResources {
    /// The resource bundle SwiftPM builds beside the executable.
    static let swiftPMBundleName = "PowerMateDriver_PowerMateDriver.bundle"

    static func path(forResource name: String, ofType ext: String, mainBundle: Bundle = .main) -> String? {
        // The packaged app: images are in Contents/Resources.
        if let path = mainBundle.path(forResource: name, ofType: ext) {
            return path
        }
        // `swift run`: SwiftPM puts them in its bundle next to the executable.
        let swiftPMBundle = Bundle(url: mainBundle.bundleURL.appendingPathComponent(swiftPMBundleName))
        return swiftPMBundle?.path(forResource: name, ofType: ext)
    }
}
