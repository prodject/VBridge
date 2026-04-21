// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let wireguardGoOutDirectory = "\(packageDirectory)/Sources/WireGuardKitGo/out"

let package = Package(
    name: "WireGuardKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"]),
        .library(name: "WireGuardKitGo", targets: ["WireGuardKitGo"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WireGuardKit",
            dependencies: ["WireGuardKitGo", "WireGuardKitC"]
        ),
        .target(
            name: "WireGuardKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "WireGuardKitGo",
            dependencies: [],
            exclude: [
                "goruntime-boottime-over-monotonic.diff",
                "go.mod",
                "go.sum",
                "api-apple.go",
                "api-xray.go",
                "Makefile"
            ],
            publicHeadersPath: ".",
            linkerSettings: [
                .unsafeFlags(["-L", wireguardGoOutDirectory]),
                .linkedLibrary("wg-go"),
                .linkedLibrary("resolv")
            ]
        ),
        .testTarget(
            name: "WireGuardKitTests",
            dependencies: ["WireGuardKit"]
        )
    ]
)
