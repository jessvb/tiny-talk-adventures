// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TinyTalkCore",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "TinyTalkCore", targets: ["TinyTalkCore"]),
        .library(name: "TinyTalkPlatform", targets: ["TinyTalkPlatform"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.2"),
    ],
    targets: [
        .target(name: "TinyTalkCore"),
        .testTarget(name: "TinyTalkCoreTests", dependencies: ["TinyTalkCore"]),
        .target(
            name: "TinyTalkPlatform",
            dependencies: [
                "TinyTalkCore",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ]
        ),
    ]
)
