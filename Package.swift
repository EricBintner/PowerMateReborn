// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PowerMateDriver",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "PowerMateDriver",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
