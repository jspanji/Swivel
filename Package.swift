// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Swivel",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Sparkle handles auto-update: appcast polling, EdDSA signature
        // verification, atomic in-place install, and the standard
        // "Check for Updates…" UI. We use the SPM distribution; the
        // private signing key stays in the maintainer's keychain.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // All logic + UI lives here so the test target can reach it via
        // `@testable import SwivelCore`.
        .target(
            name: "SwivelCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SwivelCore"
        ),
        // Thin shell: just `main.swift` → `launchSwivel()`.
        .executableTarget(
            name: "Swivel",
            dependencies: ["SwivelCore"],
            path: "Sources/Swivel"
        ),
        .testTarget(
            name: "SwivelCoreTests",
            dependencies: ["SwivelCore"],
            path: "Tests/SwivelCoreTests"
        )
    ]
)
