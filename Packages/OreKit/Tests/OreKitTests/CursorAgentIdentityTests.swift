import Foundation
import Testing

@testable import OreHarness
@testable import OreProtocol

/// Which binary ORE is willing to drive as cursor-agent.
///
/// Cursor renamed its command from `cursor-agent` to `agent`, so ORE has to
/// look for both. `agent` is a name anything can have, though — a project's
/// own helper script, another vendor's CLI, something on a shared machine —
/// and adopting whatever answers to it meant ORE reported an agent as
/// installed, offered it in the picker, and failed the user's first turn with
/// output from a program that had nothing to do with Cursor.
struct CursorAgentIdentityTests {
    @Test func theUnambiguousNameIsTrustedAsFound() {
        #expect(CursorAgentHarness.identifiesAsCursorAgent(
            isAmbiguousName: false, version: "2025.09.01-abcdef"
        ))
    }

    /// A CLI that will not answer `--version` is a different problem, and not
    /// this check's to diagnose — under its own name it is still accepted.
    @Test func theUnambiguousNameIsTrustedEvenWithNoVersion() {
        #expect(CursorAgentHarness.identifiesAsCursorAgent(
            isAmbiguousName: false, version: nil
        ))
    }

    @Test func theGenericNameIsAcceptedWhenItSaysItIsCursor() {
        #expect(CursorAgentHarness.identifiesAsCursorAgent(
            isAmbiguousName: true, version: "cursor-agent 2025.09.01"
        ))
        // Case is the vendor's to choose, not ours to depend on.
        #expect(CursorAgentHarness.identifiesAsCursorAgent(
            isAmbiguousName: true, version: "Cursor Agent 1.2.3"
        ))
    }

    @Test func aStrangerNamedAgentIsRejected() {
        #expect(!CursorAgentHarness.identifiesAsCursorAgent(
            isAmbiguousName: true, version: "agent 1.0.0 (some other vendor)"
        ))
        #expect(!CursorAgentHarness.identifiesAsCursorAgent(
            isAmbiguousName: true, version: nil
        ))
        #expect(!CursorAgentHarness.identifiesAsCursorAgent(
            isAmbiguousName: true, version: ""
        ))
    }
}
