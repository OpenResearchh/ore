// swift-tools-version: 6.0
import PackageDescription

// The Mac app.
//
// It depends on the core's public vocabulary — the command/event enums, and the
// value types they carry (diffs, git actions) — and never on the harness or
// persistence layers. Every capability goes through `CoreClient`, which is what
// keeps a hosted version of ORE possible: swap `InProcessCoreClient` for one
// speaking the same two enums over a socket and the UI is unchanged.
let package = Package(
    name: "OreMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OreMac", targets: ["OreMac"]),
    ],
    dependencies: [
        .package(path: "../../Packages/OreKit"),
        // Markdown in agent replies is the norm, not the exception.
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0"),
        // Syntax highlighting for code blocks and diffs.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.9.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json.git", branch: "master"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift.git", branch: "with-generated-files"),
        // The terminal pane.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.9.0"),
        // In-app updates.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
        // Neural on-device TTS. Apple's voices are intelligible but plainly
        // synthetic; narration is listened to for minutes at a time, so the
        // voice is the feature.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "OreMac",
            dependencies: [
                .product(name: "OreCore", package: "OreKit"),
                .product(name: "OreGit", package: "OreKit"),
                .product(name: "OreProtocol", package: "OreKit"),
                // Anonymous usage analytics. The app is the only thing that
                // links this: nothing inside OreKit depends on it, which is
                // what makes it impossible for the headless core to report.
                .product(name: "OreTelemetry", package: "OreKit"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [
                .copy("Resources/HarnessIcons"),
                // LICENSE, NOTICE and every dependency's license text, so the
                // notices travel with the binary (Scripts/generate-legal-resources.sh).
                .copy("Resources/Legal"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "OreMacTests",
            dependencies: [
                "OreMac",
                .product(name: "OreProtocol", package: "OreKit"),
                .product(name: "OreTelemetry", package: "OreKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
