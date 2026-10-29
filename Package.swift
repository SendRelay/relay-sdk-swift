// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RelaySDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "RelaySDK", targets: ["RelaySDK"]),
    ],
    targets: [
        .target(name: "RelaySDK"),
        .testTarget(name: "RelaySDKTests", dependencies: ["RelaySDK"]),
    ]
)
