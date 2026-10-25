// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DynamicNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DynamicNotch", targets: ["DynamicNotch"]),
        .executable(name: "notch", targets: ["notch"]),
    ],
    targets: [
        // Shared wire protocol + socket client, used by both the app and the CLI.
        .target(name: "NotchKit"),
        .executableTarget(name: "DynamicNotch", dependencies: ["NotchKit"]),
        .executableTarget(name: "notch", dependencies: ["NotchKit"]),
    ]
)
