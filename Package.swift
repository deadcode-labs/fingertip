// swift-tools-version: 6.2
//
// El núcleo de fingertip sin UI: drivers (simulador y macOS), Jev y el loop
// del agente. Lo usan la app y `fingertip-mcp`, el servidor MCP con el que
// Claude Code hace las pruebas manuales.
//
// Mismos ajustes de concurrencia que el target de la app: MainActor por
// defecto y "approachable concurrency".

import PackageDescription

let concurrency: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "FingertipCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "FingertipCore", targets: ["FingertipCore"]),
        .executable(name: "fingertip-mcp", targets: ["fingertip-mcp"]),
    ],
    targets: [
        .target(name: "FingertipCore", swiftSettings: concurrency),
        .executableTarget(
            name: "fingertip-mcp",
            dependencies: ["FingertipCore"],
            swiftSettings: concurrency
        ),
    ]
)
