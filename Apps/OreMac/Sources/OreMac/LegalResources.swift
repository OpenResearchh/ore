import AppKit
import Foundation

/// The app target's SwiftPM resource bundle, found where it actually is.
///
/// SwiftPM's generated `Bundle.module` resolves the resource bundle from
/// `Bundle.main.bundleURL` (the app *root*) and a build-time absolute path —
/// neither of which matches a packaged `.app`, where the bundle lands in
/// `Contents/Resources`. On a distributed build both lookups miss and
/// `Bundle.module` *traps*. Resolve the bundle across the real locations and
/// fall back to the main bundle, whose lookups return nil rather than crash.
@MainActor
enum OreResourceBundle {
    static let bundle: Bundle = {
        let name = "OreMac_OreMac.bundle"
        let code = Bundle(for: BundleToken.self)
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name), // Contents/Resources — packaged app
            Bundle.main.bundleURL.appendingPathComponent(name),    // app root — SwiftPM's expectation
            code.resourceURL?.appendingPathComponent(name),
            code.bundleURL.appendingPathComponent(name),
            // Beside the test bundle, under `swift test`.
            code.bundleURL.deletingLastPathComponent().appendingPathComponent(name),
        ]
        for case let url? in candidates
        where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        // Last resort: resources may have been flattened into Contents/Resources.
        return .main
    }()

    private final class BundleToken {}
}

/// Who makes ORE and where to find it, stated once for the About section.
enum OreAbout {
    static let company = "Jupiter Innovations Lab Inc."
    static let copyright = "Copyright © 2026 Jupiter Innovations Lab Inc."
    static let licenseName = "Apache License 2.0"
    static let website = URL(string: "https://openresearchh.com/ore")!
    static let repository = URL(string: "https://github.com/OpenResearchh/ore")!
    static let releaseNotes = URL(string: "https://github.com/OpenResearchh/ore/releases")!
    static let privacyContact = URL(string: "mailto:privacy@openresearchh.com")!

    /// "0.7.2 (202609142310)", or a plain note for a build that was never
    /// stamped — a bare `swift run` has no Info.plist to read.
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else {
            return "Development build"
        }
        guard let build = info?["CFBundleVersion"] as? String, build != short, build != "1" else {
            return short
        }
        return "\(short) (\(build))"
    }
}

/// One piece of open-source work ORE is built on.
struct ThirdPartyComponent: Identifiable, Hashable {
    let name: String
    /// The `Package.resolved` identity; nil for work that isn't a Swift package.
    let packageIdentity: String?
    let license: String
    let credit: String
    let url: URL
    let purpose: String

    var id: String { name }

    /// Mirrors NOTICE. `LegalResourcesTests` keeps it in step with
    /// `Package.resolved`, so a new dependency can't ship unacknowledged.
    static let all: [ThirdPartyComponent] = [
        .init(name: "FluidAudio", packageIdentity: "fluidaudio",
              license: "Apache License 2.0", credit: "FluidInference",
              url: URL(string: "https://github.com/FluidInference/FluidAudio")!,
              purpose: "Runs the neural narration voice on this Mac"),
        .init(name: "GRDB.swift", packageIdentity: "grdb.swift",
              license: "MIT License", credit: "Copyright (C) 2015-2025 Gwendal Roué",
              url: URL(string: "https://github.com/groue/GRDB.swift")!,
              purpose: "The local database"),
        .init(name: "Pocket TTS", packageIdentity: nil,
              license: "CC BY 4.0", credit: "Kyutai",
              url: URL(string: "https://huggingface.co/kyutai/pocket-tts")!,
              purpose: "The neural narration voice model, downloaded on demand"),
        .init(name: "Sparkle", packageIdentity: "sparkle",
              license: "MIT License",
              credit: "Copyright (c) 2006-2013 Andy Matuschak and the Sparkle Project contributors",
              url: URL(string: "https://github.com/sparkle-project/Sparkle")!,
              purpose: "In-app updates"),
        .init(name: "swift-argument-parser", packageIdentity: "swift-argument-parser",
              license: "Apache License 2.0", credit: "Copyright (c) Apple Inc. and the Swift project authors",
              url: URL(string: "https://github.com/apple/swift-argument-parser")!,
              purpose: "The ore command-line tool"),
        .init(name: "swift-cmark", packageIdentity: "swift-cmark",
              license: "BSD 2-Clause License", credit: "Copyright (c) 2014, John MacFarlane",
              url: URL(string: "https://github.com/swiftlang/swift-cmark")!,
              purpose: "Markdown parsing"),
        .init(name: "swift-markdown", packageIdentity: "swift-markdown",
              license: "Apache License 2.0", credit: "Copyright (c) Apple Inc. and the Swift project authors",
              url: URL(string: "https://github.com/apple/swift-markdown")!,
              purpose: "Markdown in agent replies"),
        .init(name: "SwiftTerm", packageIdentity: "swiftterm",
              license: "MIT License", credit: "Copyright (c) 2019-2026 Miguel de Icaza",
              url: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!,
              purpose: "The terminal pane"),
        .init(name: "SwiftTreeSitter", packageIdentity: "swifttreesitter",
              license: "BSD 3-Clause License", credit: "Copyright (c) 2021, Chime",
              url: URL(string: "https://github.com/ChimeHQ/SwiftTreeSitter")!,
              purpose: "Syntax highlighting"),
        .init(name: "tree-sitter", packageIdentity: "tree-sitter",
              license: "MIT License", credit: "Copyright (c) 2018-2024 Max Brunsfeld",
              url: URL(string: "https://github.com/tree-sitter/tree-sitter")!,
              purpose: "Syntax highlighting"),
        .init(name: "tree-sitter-json", packageIdentity: "tree-sitter-json",
              license: "MIT License", credit: "Copyright (c) 2014 Max Brunsfeld",
              url: URL(string: "https://github.com/tree-sitter/tree-sitter-json")!,
              purpose: "The JSON grammar"),
        .init(name: "tree-sitter-swift", packageIdentity: "tree-sitter-swift",
              license: "MIT License", credit: "Copyright (c) 2021 alex-pinkus",
              url: URL(string: "https://github.com/alex-pinkus/tree-sitter-swift")!,
              purpose: "The Swift grammar"),
    ]
}

/// The legal texts bundled with the app (see Scripts/generate-legal-resources.sh).
enum LegalDocument: String, CaseIterable, Identifiable {
    case license = "LICENSE"
    case notice = "NOTICE"
    case thirdPartyLicenses = "ThirdPartyLicenses"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .license: "ORE License"
        case .notice: "Notice"
        case .thirdPartyLicenses: "Third-Party Licenses"
        }
    }

    /// Read when asked, never while Settings draws: its body re-runs every
    /// display cycle.
    @MainActor
    var text: String? {
        guard let url = OreResourceBundle.bundle.url(
            forResource: rawValue, withExtension: "txt", subdirectory: "Legal"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
