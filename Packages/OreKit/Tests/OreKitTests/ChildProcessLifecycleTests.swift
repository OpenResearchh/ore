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

    @Test func sequentialShortProcessesCloseEveryPipeTheyWereGiven() async throws {
        // Counting /dev/fd can't answer this. Every other suite runs in this
        // same process, and on Linux, where launches are serialized, over two
        // hundred pipes from their git calls can be open at the moment of the
        // second count. So the test follows the exact pipe ends these
        // processes were given, by inode, and checks none of them is left.
        var pipeEnds: [DescriptorIdentity] = []
        for _ in 0..<60 {
            pipeEnds += try await runToCompletion()
        }
        // Three pipes, two ends each, per process.
        #expect(pipeEnds.count == 60 * 6)

        // Stdin closes on the write queue, which a busy CI runner can take
        // well over 200 ms to reach. A real leak stays open however long this
        // waits, so wait for the last close instead of guessing a delay.
        var leaked = pipeEnds.filter(\.isStillOpen)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !leaked.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            leaked = leaked.filter(\.isStillOpen)
        }
        #expect(leaked.count == 0, "\(leaked.count) pipe ends are still open")
    }

    private func runToCompletion() async throws -> [DescriptorIdentity] {
        let process = try shell("echo out; echo err >&2")
        process.closeStandardInput()
        async let stdout = process.stdoutChunks.collectText()
        async let stderr = process.stderrChunks.collectText()
        _ = await stdout
        _ = await stderr
        #expect(await process.waitForExit() == 0)
        return process.pipeDescriptors
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
