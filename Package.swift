// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIBar",
            path: "Sources/AIBar"
        )
    ]
)
