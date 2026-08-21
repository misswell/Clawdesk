// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Clawdesk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Clawdesk", targets: ["Clawdesk"]),
        .executable(name: "ClawdeskStatusline", targets: ["ClawdeskStatusline"]),
        .executable(name: "ClawdeskUpdater", targets: ["ClawdeskUpdater"])
    ],
    targets: [
        .executableTarget(
            name: "Clawdesk",
            path: "Sources/Clawdesk"
        ),
        .executableTarget(
            name: "ClawdeskStatusline",
            path: "Sources/ClawdeskStatusline"
        ),
        .executableTarget(
            name: "ClawdeskUpdater",
            path: "Sources/ClawdeskUpdater"
        ),
        .testTarget(
            name: "ClawdeskTests",
            dependencies: ["Clawdesk", "ClawdeskUpdater"],
            path: "Tests/ClawdeskTests"
        )
    ]
)
