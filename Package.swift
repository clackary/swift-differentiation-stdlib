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
        // url and checksum are rewritten by Tools/release.sh. The artifact is
        // published as a release asset rather than committed: SwiftPM verifies
        // the download against the checksum, so the repository does not have to
        // carry a binary that changes on every rebuild.
        //
        // For local work against a rebuilt xcframework, use
        //   swift package edit swift-differentiation-stdlib --path <checkout>
        // in the consuming package.
        .binaryTarget(
            name: "_Differentiation",
            url: "https://github.com/clackary/swift-differentiation-stdlib/releases/download/603.3.0-test-2/_Differentiation-swift-6.3.3-RELEASE.xcframework.zip",
            checksum: "64cf457a90d8bf41fcfd2a30bcc3b48c4f3d46937635dc9d7e85c2fe9c0f6327"
        ),
        .testTarget(
            name: "DifferentiationTests",
            dependencies: ["_Differentiation"]
        ),
    ]
)
