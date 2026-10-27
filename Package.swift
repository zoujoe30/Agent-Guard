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
        // Official Sparkle 2.10.1 SPM artifact and checksum from its Package.swift.
        .binaryTarget(name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"),
        .target(
            name: "AgentGuardCore",
            path: "Sources/AgentGuardCore"
        ),
        .executableTarget(
            name: "AgentGuard",
            dependencies: ["AgentGuardCore", "Sparkle"],
            path: "Sources/AgentGuard",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
