// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DDOffKeyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DDOffKeyCore", targets: ["DDOffKeyCore"])
    ],
    targets: [
        .target(
            name: "DDOffKeyCore",
            path: "boringNotch/offkey/Core"
        ),
        .testTarget(
            name: "DDOffKeyCoreTests",
            dependencies: ["DDOffKeyCore"],
            path: "Tests/DDOffKeyCoreTests"
        )
    ]
)
