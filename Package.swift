// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ANChor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BoseKit", targets: ["BoseKit"]),
        .executable(name: "ANChor", targets: ["ANChor"]),
    ],
    targets: [
        .target(
            name: "BoseKit",
            path: "Sources/BoseKit",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "ANChor",
            dependencies: ["BoseKit"],
            path: "Sources/ANChor",
            linkerSettings: [
                .linkedFramework("Cocoa"),
            ]
        ),
    ]
)
