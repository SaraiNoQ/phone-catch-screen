// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ScreenBeam",
    platforms: [
        // SCScreenshotManager (ScreenCaptureKit one-shot capture) requires macOS 14.
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScreenBeamCore", targets: ["ScreenBeamCore"]),
        .executable(name: "screenbeam", targets: ["screenbeam"]),
    ],
    targets: [
        .target(
            name: "ScreenBeamCore",
            path: "Sources/ScreenBeamCore"
        ),
        .executableTarget(
            name: "screenbeam",
            dependencies: ["ScreenBeamCore"],
            path: "Sources/screenbeam"
        ),
    ]
)
