import CoreML
import FluidAudio
import Foundation
import Testing
@testable import OreMac

/// The unit tests in `NeuralVoiceIncompleteDownloadTests` build fake trees;
/// these hold the two claims about FluidAudio they rest on against the real
/// downloader and real weights:
///
/// - a pack whose required directories all exist is never refetched, however
///   broken one of them is — the state that stranded a working Mac;
/// - a fetch that is going to run resumes a `.partial`, so clearing before it
///   must leave that download alone.
///
/// Opt-in, because they need the installed English pack (cloned per test —
/// free on APFS) and the network for the models they remove:
///
///     ORE_FLUIDAUDIO_INTEGRATION=1 swift test --filter NeuralVoiceCacheIntegrationTests
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["ORE_FLUIDAUDIO_INTEGRATION"] == "1"),
    .serialized,
    .timeLimit(.minutes(10))
)
struct NeuralVoiceCacheIntegrationTests {
    private static let installedRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/fluidaudio")

    /// A private copy of the installed cache, so nothing here can touch the
    /// voice the app is actually using.
    private func cloneInstalledCache() throws -> (root: URL, pack: URL) {
        let installedPack = NeuralNarrationVoice.languagePackDirectory(
            cacheRoot: Self.installedRoot
        )
        try #require(
            FileManager.default.fileExists(atPath: installedPack.path),
            "Install the neural voice once before running these."
        )
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pack = NeuralNarrationVoice.languagePackDirectory(cacheRoot: root)
        try FileManager.default.createDirectory(
            at: pack.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: installedPack, to: pack)
        return (root, pack)
    }

    private func ensureModels(
        in root: URL,
        progress: ProgressHandler? = nil
    ) async throws {
        _ = try await PocketTtsResourceDownloader.ensureModels(
            language: NeuralNarrationVoice.modelLanguage,
            directory: root,
            precision: NeuralNarrationVoice.modelPrecision,
            placement: NeuralNarrationVoice.modelPlacement,
            progressHandler: progress
        )
    }

    private func partials(in pack: URL) -> [URL] {
        let walk = FileManager.default.enumerator(at: pack, includingPropertiesForKeys: nil)
        return (walk?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "partial" }
    }

    /// Every required model loads in CoreML, which is the whole point.
    private func expectLoadable(_ pack: URL) throws {
        for name in NeuralNarrationVoice.requiredModelNames.sorted()
        where name.hasSuffix(".mlmodelc") {
            _ = try MLModel(contentsOf: pack.appendingPathComponent(name))
        }
    }

    @Test func aStuckModelIsRefetchedOnlyOnceItIsCleared() async throws {
        let cache = try cloneInstalledCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let mimi = cache.pack.appendingPathComponent("mimi_decoder.mlmodelc")
        let manifest = mimi.appendingPathComponent(NeuralNarrationVoice.compiledModelManifest)
        try FileManager.default.removeItem(at: manifest)

        // The bug, reproduced against the vendor: it sees the directory and
        // downloads nothing, so the model stays unloadable.
        #expect(NeuralNarrationVoice.fetchWillBeSkipped(languagePack: cache.pack))
        try await ensureModels(in: cache.root)
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        #expect(throws: (any Error).self) { try MLModel(contentsOf: mimi) }

        // The fix: exactly that directory goes, and the fetch replaces it.
        let clear = NeuralNarrationVoice.modelsToClearBeforeFetch(in: cache.pack)
        #expect(clear.map(\.lastPathComponent) == ["mimi_decoder.mlmodelc"])
        for model in clear { try FileManager.default.removeItem(at: model) }
        try await ensureModels(in: cache.root)
        #expect(NeuralNarrationVoice.incompleteCompiledModels(in: cache.pack).isEmpty)
        try expectLoadable(cache.pack)
    }

    @Test func aCancelledDownloadSurvivesTheClearAndCompletes() async throws {
        let cache = try cloneInstalledCache()
        defer { try? FileManager.default.removeItem(at: cache.root) }
        // Two models gone, so cancelling during the first leaves the second
        // missing — a fetch that is going to run.
        for name in ["flow_decoder_fused.mlmodelc", "mimi_decoder.mlmodelc"] {
            try FileManager.default.removeItem(at: cache.pack.appendingPathComponent(name))
        }

        let fetch = Task { try await ensureModels(in: cache.root) }
        let deadline = Date().addingTimeInterval(120)
        while partials(in: cache.pack).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        fetch.cancel()
        _ = await fetch.result
        let interrupted = partials(in: cache.pack)
        try #require(!interrupted.isEmpty, "The fetch finished before it could be cancelled.")

        #expect(!NeuralNarrationVoice.fetchWillBeSkipped(languagePack: cache.pack))
        #expect(NeuralNarrationVoice.modelsToClearBeforeFetch(in: cache.pack).isEmpty)
        for partial in interrupted {
            #expect(FileManager.default.fileExists(atPath: partial.path))
        }

        try await ensureModels(in: cache.root)
        #expect(partials(in: cache.pack).isEmpty)
        #expect(NeuralNarrationVoice.incompleteCompiledModels(in: cache.pack).isEmpty)
        try expectLoadable(cache.pack)
    }
}
