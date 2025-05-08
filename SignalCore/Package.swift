// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "SignalCore",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "SignalCore",
            targets: ["SignalCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/aws-amplify/aws-sdk-ios-spm", from: "2.33.0"),
        .package(path: "../SignalServiceKit")
    ],
    targets: [
        .target(
            name: "SignalCore",
            dependencies: [
                .product(name: "AWSCore", package: "aws-sdk-ios-spm"),
                .product(name: "AWSS3", package: "aws-sdk-ios-spm"),
                .product(name: "AWSDynamoDB", package: "aws-sdk-ios-spm"),
                "SignalServiceKit"
            ]),
    ]
) 