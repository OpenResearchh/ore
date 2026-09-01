import Foundation
import Testing

@testable import OreCore
@testable import OrePersistence
@testable import OreSupport

struct ProcessLaunchTests {
    @Test func concurrentShortLivedGitProcessesDoNotCrash() async throws {
        let git = try #require(ShellEnvironment.locate("git") ?? executableGit())
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ore-proc-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true
                    )
                    defer { try? FileManager.default.removeItem(at: dir) }
                    let process = try ChildProcess(
                        executablePath: git,
                        arguments: ["--version"],
                        workingDirectory: dir,
                        environment: ProcessInfo.processInfo.environment
                    )
                    process.closeStandardInput()
                    async let stdout = process.stdoutChunks.collectText()
                    async let stderr = process.stderrChunks.collectText()
                    _ = await stdout
                    _ = await stderr
                    return await process.waitForExit()
                }
            }
            var statuses: [Int32] = []
            for try await status in group { statuses.append(status) }
            #expect(statuses.allSatisfy { $0 == 0 })
            #expect(statuses.count == 16)
        }
    }

    @Test func assistantHomeGitDoesNotRaceOtherLaunches() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let root = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ore-asst-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: root, withIntermediateDirectories: true
                    )
                    defer { try? FileManager.default.removeItem(at: root) }
                    let store = try OreStore(path: root.appendingPathComponent("ore.sqlite"))
                    let record = try await AssistantManager.ensureAssistant(store: store)
                    #expect(record != nil)
                }
            }
            for _ in 0..<8 {
                group.addTask {
                    let git = try #require(ShellEnvironment.locate("git") ?? executableGit())
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ore-git-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true
                    )
                    defer { try? FileManager.default.removeItem(at: dir) }
                    let process = try ChildProcess(
                        executablePath: git,
                        arguments: ["init", "--initial-branch", "main"],
                        workingDirectory: dir,
                        environment: ProcessInfo.processInfo.environment
                    )
                    process.closeStandardInput()
                    async let stdout = process.stdoutChunks.collectText()
                    async let stderr = process.stderrChunks.collectText()
                    _ = await stdout
                    _ = await stderr
                    #expect(await process.waitForExit() == 0)
                }
            }
            try await group.waitForAll()
        }
    }
}

private func executableGit() -> String? {
    FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : nil
}
