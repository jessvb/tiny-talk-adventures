// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TinyTalkCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TinyTalkCore", targets: ["TinyTalkCore"]),
        .library(name: "TinyTalkPlatform", targets: ["TinyTalkPlatform"]),
    ],
    targets: [
        .target(name: "TinyTalkCore"),
        .testTarget(name: "TinyTalkCoreTests", dependencies: ["TinyTalkCore"]),
        .target(name: "TinyTalkPlatform", dependencies: ["TinyTalkCore"]),
    ]
)
