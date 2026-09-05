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
            ],
            resources: [
                // Pre-compiled via `xcrun coremlcompiler compile` -- SwiftPM's
                // .process() rule does not compile .mlmodel/.mlpackage sources
                // itself (unlike a full Xcode app target), so the committed
                // resource is already the compiled .mlmodelc form. Loaded at
                // runtime via Bundle.module + MLModel(contentsOf:) in
                // ObjectRecognizer.swift -- no Xcode-generated Swift wrapper
                // class exists for a resource bundled this way.
                .copy("Resources/FastViTT8F16.mlmodelc"),
            ]
        ),
    ]
)
