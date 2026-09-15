import Foundation
import Testing

@testable import OreSupport

/// Lifecycle guarantees behind a long-running app that spawns git and probe
/// processes all day: nothing per-process may outlive the process.
struct ChildProcessLifecycleTests {
    @Test func waitForExitAfterTheProcessHasAlreadyExited() async throws {
        let process = try shell("exit 3")
        _ = await process.stdoutChunks.collectText()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Let Foundation deliver the exit before anyone asks for it.
        try await Task.sleep(for: .milliseconds(100))

        #expect(await process.waitForExit() == 3)
    }

    @Test func waitForExitCanBeCalledRepeatedlyAndConcurrently() async throws {
        let process = try shell("sleep 0.2; exit 5")

        async let first = process.waitForExit()
        async let second = process.waitForExit()
        let statuses = await [first, second]
        #expect(statuses == [5, 5])
        #expect(await process.waitForExit() == 5)
    }

    @Test func discardedStandardErrorFinishesImmediately() async throws {
        let process = try shell("echo out; echo err >&2", discardStandardError: true)
        async let stdout = process.stdoutChunks.collectText()
        async let stderr = process.stderrChunks.collectText()
        #expect(await stdout == "out\n")
        #expect(await stderr == "")
        #expect(await process.waitForExit() == 0)
    }

    @Test func sequentialShortProcessesDoNotAccumulateFileDescriptors() async throws {
        // Warm up once so lazily-opened descriptors (dispatch, /dev/null)
        // don't count as growth.
        try await runToCompletion()
        let before = try openDescriptorCount()

        for _ in 0..<60 {
            try await runToCompletion()
        }
        // Stdin closes on the write queue; give it a beat.
        try await Task.sleep(for: .milliseconds(200))

        // A leaked process holds at least two pipe ends (120+ here). Other
        // suites run in parallel and open files too, so allow slack rather
        // than demanding an exact count.
        let growth = try openDescriptorCount() - before
        #expect(growth < 40, "open descriptors grew by \(growth)")
    }

    private func runToCompletion() async throws {
        let process = try shell("echo out; echo err >&2")
        process.closeStandardInput()
        async let stdout = process.stdoutChunks.collectText()
        async let stderr = process.stderrChunks.collectText()
        _ = await stdout
        _ = await stderr
        #expect(await process.waitForExit() == 0)
    }

    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    private func shell(_ script: String, discardStandardError: Bool = false) throws -> ChildProcess {
        try ChildProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment,
            discardStandardError: discardStandardError
        )
    }
}
