// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Teleport",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Teleport",
            path: "Sources/Teleport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
