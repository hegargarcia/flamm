// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Flamm",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Flamm", targets: ["Flamm"]),
    ],
    targets: [
        .executableTarget(name: "Flamm"),
    ]
)
