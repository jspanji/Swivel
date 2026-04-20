// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Swivel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Swivel",
            path: "Sources/Swivel"
        )
    ]
)
