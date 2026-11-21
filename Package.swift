// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Daikin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DaikinKit", targets: ["DaikinKit"]),
        .executable(name: "daikin", targets: ["daikin"]),
        .executable(name: "DaikinApp", targets: ["DaikinApp"]),
    ],
    targets: [
        .target(name: "DaikinKit"),
        .executableTarget(name: "daikin", dependencies: ["DaikinKit"]),
        // Named DaikinApp because "Daikin" would collide with the CLI binary on a case-insensitive disk.
        .executableTarget(name: "DaikinApp", dependencies: ["DaikinKit"]),
        .testTarget(name: "DaikinKitTests", dependencies: ["DaikinKit"]),
    ]
)
