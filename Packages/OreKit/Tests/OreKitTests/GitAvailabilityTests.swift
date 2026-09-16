import Foundation
import Testing

@testable import OreGit

/// Driven against a synthetic PATH rather than the machine's real git, so the
/// suite asserts the same thing on a developer's Mac, a CI runner and the
/// Linux container — none of which are the machine the interesting cases
/// describe.
struct GitAvailabilityTests {
    /// A directory holding executable shell stubs, and the environment that
    /// finds them and nothing else.
    private struct FakePath {
        let directory: URL
        var environment: [String: String] { ["PATH": directory.path, "HOME": directory.path] }

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ore-git-probe-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }

        func install(_ name: String, script: String) throws {
            let url = directory.appendingPathComponent(name)
            try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("Nothing named git on PATH is notFound, not unknown")
    func noGitOnPath() async throws {
        let path = try FakePath()
        defer { path.remove() }

        #expect(await GitAvailability.probe(environment: path.environment) == .notFound)
    }

    @Test("A git that answers is ready, and carries its version")
    func workingGit() async throws {
        let path = try FakePath()
        defer { path.remove() }
        try path.install("git", script: "echo 'git version 2.99.0'")

        let availability = await GitAvailability.probe(environment: path.environment)
        #expect(availability == .ready(version: "git version 2.99.0"))
        #expect(availability.isReady)
    }

    /// The case that produced "set your git identity" on a machine with no
    /// usable git. A non-zero exit is not evidence about which git is broken
    /// or why, so it must not become `notFound` — the ladder says nothing
    /// about `unknown` and says "install git" about `notFound`.
    @Test("A git that fails to run is unknown, never notFound")
    func brokenGit() async throws {
        let path = try FakePath()
        defer { path.remove() }
        try path.install("git", script: "echo 'xcrun: error: invalid active developer path' >&2\nexit 1")

        let availability = await GitAvailability.probe(environment: path.environment)
        #expect(availability == .unknown)
        #expect(!availability.isReady)
    }

    /// A zero exit that printed something unrecognisable is not proof that
    /// git works either.
    @Test("A git that exits cleanly but says nothing recognisable is unknown")
    func silentGit() async throws {
        let path = try FakePath()
        defer { path.remove() }
        try path.install("git", script: "echo 'not a version string'")

        #expect(await GitAvailability.probe(environment: path.environment) == .unknown)
    }

    @Test("An identity is read from whichever git is on the resolved PATH")
    func identityIsRead() async throws {
        let path = try FakePath()
        defer { path.remove() }
        try path.install("git", script: """
        case "$3" in
          user.name)  echo 'Ada Lovelace' ;;
          user.email) echo 'ada@example.com' ;;
          *)          echo 'git version 2.99.0' ;;
        esac
        """)

        #expect(await GitAvailability.probeIdentity(environment: path.environment) == true)
    }

    /// `git config --get` exits 1 for an unset key. That is a real answer —
    /// the identity is not set — and must not be confused with the probe
    /// failing.
    @Test("An unset identity is false, not nil")
    func unsetIdentityIsFalse() async throws {
        let path = try FakePath()
        defer { path.remove() }
        try path.install("git", script: """
        case "$1" in
          config) exit 1 ;;
          *)      echo 'git version 2.99.0' ;;
        esac
        """)

        #expect(await GitAvailability.probeIdentity(environment: path.environment) == false)
    }

    /// Half an identity is not an identity: git refuses to commit without
    /// both, so reporting "configured" on a name alone would move the failure
    /// to the user's first commit.
    @Test("A name with no email is not a configured identity")
    func halfAnIdentityIsFalse() async throws {
        let path = try FakePath()
        defer { path.remove() }
        try path.install("git", script: """
        case "$3" in
          user.name)  echo 'Ada Lovelace' ;;
          user.email) exit 1 ;;
          *)          echo 'git version 2.99.0' ;;
        esac
        """)

        #expect(await GitAvailability.probeIdentity(environment: path.environment) == false)
    }

    /// nil, not false. The readiness ladder shows the identity rung only when
    /// it has an answer, so that a user with no git is told about git rather
    /// than sent to run a `git config` that will fail the same way.
    @Test("With no git at all, the identity is unknown rather than unset")
    func identityWithoutGitIsNil() async throws {
        let path = try FakePath()
        defer { path.remove() }

        #expect(await GitAvailability.probeIdentity(environment: path.environment) == nil)
    }
}
