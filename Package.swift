// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Clawdesk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Clawdesk", targets: ["Clawdesk"]),
        .executable(name: "ClawdeskStatusline", targets: ["ClawdeskStatusline"])
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
        .testTarget(
            name: "ClawdeskTests",
            dependencies: ["Clawdesk"],
            path: "Tests/ClawdeskTests"
        )
    ]
)
