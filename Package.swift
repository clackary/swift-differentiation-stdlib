// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-differentiation-stdlib",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0"),
    ],
    products: [
        .library(
            name: "_Differentiation",
            targets: ["_Differentiation"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "_Differentiation",
            path: "_Differentiation.xcframework"
        ),
        .testTarget(
            name: "DifferentiationTests",
            dependencies: ["_Differentiation"]
        ),
    ]
)
