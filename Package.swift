// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PowerMateDriver",
    // The English text in the code is the base language; fi.lproj translates it.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.0")
    ],
    targets: [
        .executableTarget(
            name: "PowerMateDriver",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("Sparkle", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "PowerMateDriverTests",
            dependencies: ["PowerMateDriver"],
            path: "Tests/PowerMateDriverTests"
        )
    ]
)
