// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyTool",
    dependencies: [
        // existing dependency
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        // ▼ add swift-log
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyTool",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                // ▼ link the Logging product
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
