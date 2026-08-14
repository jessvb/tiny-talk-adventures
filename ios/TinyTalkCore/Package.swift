// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TinyTalkCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TinyTalkCore", targets: ["TinyTalkCore"]),
    ],
    targets: [
        .target(name: "TinyTalkCore"),
        .testTarget(name: "TinyTalkCoreTests", dependencies: ["TinyTalkCore"]),
    ]
)
