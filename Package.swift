// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Teleport",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Teleport", targets: ["Teleport"]),
        .executable(name: "simplyteleporter", targets: ["SimplyTeleporter"]),
    ],
    targets: [
        // Device plumbing shared by both front ends: the pymobiledevice3 wrapper, the
        // parked-process machinery that owns a location session, and the value types.
        .target(
            name: "TeleportCore",
            path: "Sources/TeleportCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The SwiftUI app with the map.
        .executableTarget(
            name: "Teleport",
            dependencies: ["TeleportCore"],
            path: "Sources/Teleport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The terminal front end: type `40,32`, the phone goes there.
        .executableTarget(
            name: "SimplyTeleporter",
            dependencies: ["TeleportCore"],
            path: "Sources/SimplyTeleporter",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
