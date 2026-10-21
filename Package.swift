// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wheel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Wheel", targets: ["Wheel"]),
        .library(name: "WheelCore", targets: ["WheelCore"]),
    ],
    targets: [
        // Conversion engines, the FileAction protocol and the action registry. No app UI,
        // so it can back other front ends later (Finder Quick Action, CLI, Share extension).
        .target(
            name: "WheelCore",
            path: "Sources/WheelCore"
        ),
        // The menu-bar app: drag detection, wheel, toast, editors, settings.
        .executableTarget(
            name: "Wheel",
            dependencies: ["WheelCore"],
            path: "Sources/Wheel"
        ),
        .testTarget(
            name: "WheelTests",
            dependencies: ["WheelCore", "Wheel"],
            path: "Tests/WheelTests"
        ),
    ]
)
