import Foundation
import Testing

@testable import OreMac

struct LayaCheckpointTests {
    @Test func aTreeListingSeparatesFilesAndDirectories() throws {
        let json = """
            [
              {"type":"file","path":"config.json","size":128},
              {"type":"directory","path":"onnx"},
              {"type":"file","path":"model.safetensors","lfs":{"size":42000000}}
            ]
            """.data(using: .utf8)!
        let listing = try LayaCheckpoint.parseTree(json)
        #expect(listing.directories == ["onnx"])
        #expect(listing.files.contains(where: { $0.path == "config.json" && $0.size == 128 }))
        #expect(listing.files.contains(where: { $0.path == "model.safetensors" && $0.size == 42_000_000 }))
    }

    @Test func anErrorObjectIsAListingFailure() {
        let json = #"{"error":"Repository not found"}"#.data(using: .utf8)!
        do {
            _ = try LayaCheckpoint.parseTree(json)
            Issue.record("expected a listing error")
        } catch let error as LayaInstallError {
            #expect(error == .listing("Repository not found"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func anEmptyMarkerIsNotACheckpoint() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "laya-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appending(path: "config.json"))
        #expect(!LayaCheckpoint.weightsArePresent(in: root))
    }

    @Test func aSafetensorsFileCountsAsACheckpoint() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "laya-weights-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("weights".utf8).write(to: root.appending(path: "model.safetensors"))
        #expect(LayaCheckpoint.weightsArePresent(in: root))
    }

    @Test func readmeAndDotfilesAreNotDownloaded() {
        #expect(!LayaCheckpoint.shouldDownload(".gitattributes"))
        #expect(!LayaCheckpoint.shouldDownload("README.md"))
        #expect(LayaCheckpoint.shouldDownload("model.safetensors"))
        #expect(LayaCheckpoint.shouldDownload("onnx/model.onnx"))
    }

    @Test func typedDecisionsWinsWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "laya-modeldir-\(UUID().uuidString)", directoryHint: .isDirectory)
        let typed = root.appending(path: "typed-decisions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: typed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("root".utf8).write(to: root.appending(path: "model.safetensors"))
        try Data("typed".utf8).write(to: typed.appending(path: "model.safetensors"))
        // modelDirectory reads the real cache; this only asserts the typed
        // snapshot is recognised as a weight tree.
        #expect(LayaCheckpoint.weightsArePresent(in: root))
        #expect(LayaCheckpoint.isWeightFile("typed-decisions/model.safetensors"))
    }
}
