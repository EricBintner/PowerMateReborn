import XCTest
@testable import PowerMateDriver

/// v1.2.2 looked images up through SwiftPM's `Bundle.module`, which stops the
/// app when its resource bundle is missing. The packaged app has no such
/// bundle (and the fallback path only exists on the build machine), so About
/// and Quick Start crashed for everyone except the developer.
final class AppResourcesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppResourcesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ names: [String], into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try Data("image".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    /// An app laid out the way scripts/build-dmg.sh does it: images copied
    /// straight into Contents/Resources, and no SwiftPM resource bundle.
    private func packagedApp(containing names: [String]) throws -> Bundle {
        let app = root.appendingPathComponent("PowerMateReborn.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try write(names, into: contents.appendingPathComponent("Resources", isDirectory: true))
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.PowerMateReborn", "CFBundlePackageType": "APPL"],
            format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: app))
    }

    /// A `swift run` build folder: the executable's directory with SwiftPM's
    /// resource bundle beside it.
    private func buildFolder(containing names: [String]) throws -> Bundle {
        let folder = root.appendingPathComponent("debug", isDirectory: true)
        try write(names, into: folder.appendingPathComponent(AppResources.swiftPMBundleName, isDirectory: true))
        return try XCTUnwrap(Bundle(url: folder))
    }

    private func resolved(_ path: String?) -> String? {
        return path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    func testPackagedAppFindsItsImagesWithoutASwiftPMBundle() throws {
        let app = try packagedApp(containing: ["logo.svg"])
        let expected = app.bundleURL.appendingPathComponent("Contents/Resources/logo.svg")
            .resolvingSymlinksInPath().path
        XCTAssertEqual(resolved(AppResources.path(forResource: "logo", ofType: "svg", mainBundle: app)), expected)
    }

    func testDevelopmentBuildFindsImagesInTheSwiftPMBundle() throws {
        let folder = try buildFolder(containing: ["logo.svg"])
        let expected = folder.bundleURL.appendingPathComponent(AppResources.swiftPMBundleName)
            .appendingPathComponent("logo.svg").resolvingSymlinksInPath().path
        XCTAssertEqual(resolved(AppResources.path(forResource: "logo", ofType: "svg", mainBundle: folder)), expected)
    }

    func testImageMissingFromThePackagedAppIsNilNotACrash() throws {
        let app = try packagedApp(containing: ["logo.svg"])
        XCTAssertNil(AppResources.path(forResource: "no-such-image", ofType: "png", mainBundle: app))
    }

    func testFolderWithNoResourcesAtAllIsNilNotACrash() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let bundle = try XCTUnwrap(Bundle(url: empty))
        XCTAssertNil(AppResources.path(forResource: "logo", ofType: "svg", mainBundle: bundle))
    }
}
