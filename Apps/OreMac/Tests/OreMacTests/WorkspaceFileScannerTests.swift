import Foundation
import Testing

@testable import OreMac

struct WorkspaceFileScannerTests {
    @Test func rootSiblingsSurviveALargeDotFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-file-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let attachments = root
            .appendingPathComponent(".context/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        for index in 0..<40 {
            try Data("x".utf8).write(
                to: attachments.appendingPathComponent("shot-\(index).png")
            )
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("let x = 1\n".utf8).write(
            to: root.appendingPathComponent("src/App.swift")
        )
        try Data("# hi\n".utf8).write(to: root.appendingPathComponent("README.md"))

        let names = Set(
            WorkspaceFileScanner(fileLimit: 10, hideNames: [".git", ".DS_Store", ".context"], skipRecursionNames: [])
                .scan(at: root.path)
                .map(\.name)
        )
        #expect(names.contains("src"))
        #expect(names.contains("README.md"))
        #expect(!names.contains(".context"))
    }

    @Test func aBudgetEatenByTheFirstFolderStillListsLaterRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-file-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent(".cache", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        for index in 0..<20 {
            try Data("x".utf8).write(to: first.appendingPathComponent("f-\(index).dat"))
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ok\n".utf8).write(to: root.appendingPathComponent("src/main.py"))

        // Recurse into `.cache` (not skipped) with a tiny budget so the old
        // depth-first compactMap would `return nil` for `src`.
        let tree = WorkspaceFileScanner(
            fileLimit: 5,
            hideNames: [".git"],
            skipRecursionNames: []
        ).scan(at: root.path)
        let names = Set(tree.map(\.name))
        #expect(names.contains(".cache"))
        #expect(names.contains("src"))
    }

    @Test func skipRecursionLeavesJunkAsAnEmptyFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-file-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modules = root.appendingPathComponent("node_modules/left-pad", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("module.exports = 1\n".utf8).write(to: modules.appendingPathComponent("index.js"))
        try Data("hi\n".utf8).write(to: root.appendingPathComponent("index.js"))

        let tree = WorkspaceFileScanner.default.scan(at: root.path)
        let nodeModules = tree.first { $0.name == "node_modules" }
        #expect(nodeModules?.isDirectory == true)
        #expect(nodeModules?.children?.isEmpty == true)
        #expect(tree.contains { $0.name == "index.js" })
    }
}
