// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentGuard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentGuard", targets: ["AgentGuard"]),
        .executable(name: "agent-guard", targets: ["AgentGuardCLI"]),
        .executable(name: "AgentGuardSelfTest", targets: ["AgentGuardSelfTest"])
    ],
    targets: [
        .target(
            name: "AgentGuardCore",
            path: "Sources/AgentGuardCore"
        ),
        .executableTarget(
            name: "AgentGuard",
            dependencies: ["AgentGuardCore"],
            path: "Sources/AgentGuard"
        ),
        .executableTarget(
            name: "AgentGuardCLI",
            dependencies: ["AgentGuardCore"],
            path: "Sources/AgentGuardCLI"
        ),
        .executableTarget(
            name: "AgentGuardSelfTest",
            dependencies: ["AgentGuardCore"],
            path: "Tests/AgentGuardSelfTest"
        )
    ]
)
