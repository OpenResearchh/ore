// swift-tools-version: 6.0
import PackageDescription

// OreKit is the headless core. It has no Apple-UI dependencies, so it keeps
// compiling on Linux in CI — which is what keeps the hosted/cloud version of
// ORE open as an option later.
let package = Package(
    name: "OreKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OreProtocol", targets: ["OreProtocol"]),
        .library(name: "OreSupport", targets: ["OreSupport"]),
        .library(name: "OreHarness", targets: ["OreHarness"]),
        .library(name: "OreGit", targets: ["OreGit"]),
        .library(name: "OrePersistence", targets: ["OrePersistence"]),
        .library(name: "OreCore", targets: ["OreCore"]),
        .executable(name: "ore-cli", targets: ["ore-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // The API boundary: Codable commands, events and identifiers.
        .target(name: "OreProtocol"),

        // Process and environment plumbing shared by the harness and git layers.
        .target(name: "OreSupport"),

        // Agent CLI drivers.
        .target(name: "OreHarness", dependencies: ["OreProtocol", "OreSupport"]),

        // Worktrees, status watching, diffs, checkpoints, gh.
        .target(name: "OreGit", dependencies: ["OreProtocol", "OreSupport"]),

        // SQLite storage: transcripts, workspace state, full-text search.
        .target(
            name: "OrePersistence",
            dependencies: [
                "OreProtocol", "OreSupport", .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Orchestration: one engine per workspace, plus the in-process client
        // the Mac app talks to.
        .target(
            name: "OreCore",
            dependencies: ["OreProtocol", "OreSupport", "OreHarness", "OreGit", "OrePersistence"]
        ),

        .executableTarget(name: "ore-cli", dependencies: ["OreCore", "OreSupport"]),

        .testTarget(
            name: "OreKitTests",
            dependencies: ["OreCore", "OreSupport"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
