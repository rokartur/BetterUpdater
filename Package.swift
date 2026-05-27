// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BetterUpdater",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BetterUpdater",
            targets: ["BetterUpdater"]
        ),
        .executable(
            name: "betterupdater",
            targets: ["betterupdater-cli"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // Shared, dependency-free manifest model + Ed25519/SHA-256 helpers.
        // Used by both the app-facing library (to verify) and the CLI (to sign).
        .target(
            name: "BetterUpdaterManifest"
        ),
        // App-facing updater: model, AppKit/SwiftUI UI, verification.
        .target(
            name: "BetterUpdater",
            dependencies: ["BetterUpdaterManifest"],
            resources: [
                .process("Resources/Updater.xcstrings")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Release-time signing tool: keygen | sign | verify.
        .executableTarget(
            name: "betterupdater-cli",
            dependencies: [
                "BetterUpdaterManifest",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "BetterUpdaterTests",
            dependencies: ["BetterUpdater", "BetterUpdaterManifest"]
        )
    ]
)
