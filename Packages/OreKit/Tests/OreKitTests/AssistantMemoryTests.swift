import Foundation
import OreProtocol
import Testing

@testable import OreCore

struct AssistantMemoryTests {
    /// A throwaway assistant home with a seeded index, shaped like the one
    /// `AssistantManager.ensureHome` writes.
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("memory", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "# Memory index\n\nOne line per memory file.\n".write(
            to: home.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8
        )
        return home
    }

    private func seed(_ home: URL, _ path: String, _ contents: String) throws {
        try contents.write(
            to: home.appendingPathComponent(path), atomically: true, encoding: .utf8
        )
    }

    // MARK: - Sandbox

    @Test func writesStayInsideMemoryAndRefreshTheIndex() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try AssistantMemory.write(
            home: home,
            path: "memory/preferences.md",
            contents: "# Preferences\n\nLikes short answers.\n",
            append: false
        )
        #expect(AssistantMemory.listingText(home: home).contains("memory/preferences.md"))
        #expect(try AssistantMemory.read(home: home, path: "memory/preferences.md")
            .contains("short answers"))
        #expect(AssistantMemory.readIndex(home: home).contains("memory/preferences.md"))
    }

    @Test func rejectsPathsOutsideTheSandbox() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for path in ["../etc/passwd", "memory/nested/nope.md", "memory/.hidden.md", "memory/.md"] {
            #expect(throws: AssistantMemoryError.self) {
                try AssistantMemory.write(
                    home: home, path: path, contents: "x", append: false
                )
            }
        }
    }

    /// The spelling rules above all pass for a symlink: `memory/notes.md` is
    /// exactly the shape the sandbox allows, and still reads and writes
    /// whatever it points at.
    @Test func refusesToFollowASymlinkOutOfTheHome() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let outside = home.deletingLastPathComponent()
            .appendingPathComponent("ore-outside-\(UUID().uuidString).md")
        try "secrets".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("memory/notes.md"), withDestinationURL: outside
        )

        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.read(home: home, path: "memory/notes.md")
        }
        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.write(
                home: home, path: "memory/notes.md", contents: "overwritten", append: false
            )
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "secrets")
    }

    /// A link to nowhere resolves to itself, so "is it inside the home" cannot
    /// be answered honestly about it — and an append would open a handle
    /// straight through it. Refused on shape, not on where it points.
    @Test func refusesADanglingSymlinkInsideMemory() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("memory/notes.md"),
            withDestinationURL: URL(fileURLWithPath: "/nonexistent/elsewhere.md")
        )

        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.write(
                home: home, path: "memory/notes.md", contents: "x", append: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: "/nonexistent/elsewhere.md"))
    }

    /// The old size-based test for "does this file exist" turned a failed stat
    /// into a truncating overwrite of the memory the append was adding to.
    @Test func appendingKeepsWhatWasAlreadyThere() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try AssistantMemory.write(
            home: home, path: "memory/log.md", contents: "# Log\n\nFirst fact.", append: false
        )
        try AssistantMemory.write(
            home: home, path: "memory/log.md", contents: "Second fact.", append: true
        )

        let body = try AssistantMemory.read(home: home, path: "memory/log.md")
        #expect(body.contains("First fact."))
        #expect(body.contains("Second fact."))
    }

    /// A file the model appends to on every turn would eventually crowd
    /// everything else out of the recall digest, so the boundary is enforced
    /// where the bytes land rather than left to the prompt.
    @Test func refusesAWriteThatWouldOutgrowTheFileLimit() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let big = String(repeating: "x", count: AssistantMemory.maxFileBytes + 1)
        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.write(home: home, path: "memory/big.md", contents: big, append: false)
        }
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("memory/big.md").path
        ))

        // One short of half, so the newline the append inserts still fits.
        let half = String(repeating: "y", count: AssistantMemory.maxFileBytes / 2 - 1)
        try AssistantMemory.write(home: home, path: "memory/big.md", contents: half, append: false)
        try AssistantMemory.write(home: home, path: "memory/big.md", contents: half, append: true)
        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.write(
                home: home, path: "memory/big.md", contents: half, append: true
            )
        }
        // The refused append left the file exactly as it was.
        #expect(try AssistantMemory.read(home: home, path: "memory/big.md").allSatisfy {
            $0 == "y" || $0 == "\n"
        })
    }

    // MARK: - Index hygiene

    /// The hook after each link is what a future session reads to decide which
    /// file to open, and it is the one thing this code cannot regenerate — so
    /// reconciling the index must not rewrite lines it did not have to touch.
    @Test func reconcilingTheIndexKeepsHandWrittenHooksAndProse() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "MEMORY.md", """
            # Memory index

            One line per memory file.

            - [Preferences](memory/preferences.md) — how they like things done
            - [Gone](memory/gone.md) — a topic that was deleted behind our back

            """)
        try seed(home, "memory/preferences.md", "# Preferences\n\nShort answers.\n")
        try seed(home, "memory/relations.md", "# Project relations\n\nkaguya ⇄ kailash.\n")

        try AssistantMemory.refreshIndex(home: home)
        let index = AssistantMemory.readIndex(home: home)

        #expect(index.contains("One line per memory file."))
        #expect(index.contains("- [Preferences](memory/preferences.md) — how they like things done"))
        // Added with the title the file itself declares.
        #expect(index.contains("- [Project relations](memory/relations.md)"))
        // Dropped: the index was advertising a topic with nothing behind it.
        #expect(!index.contains("memory/gone.md"))
    }

    /// The strict half of the reconciler. A line that mentions a file in
    /// passing, or links two of them, is the assistant's prose — deleting it
    /// because one target is missing destroys the hook and the sentence.
    @Test func reconcilingNeverDeletesProseThatMerelyMentionsAFile() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "MEMORY.md", """
            # Memory index

            - See [gone](memory/gone.md) and [kept](memory/kept.md) — the hook that matters
            - TODO: still need to write [routines](memory/routines.md) for the cron work
            - [Kept](memory/kept.md) — the plain entry

            """)
        try seed(home, "memory/kept.md", "# Kept\n\nStill true.\n")

        try AssistantMemory.refreshIndex(home: home)
        let index = AssistantMemory.readIndex(home: home)

        #expect(index.contains("the hook that matters"))
        #expect(index.contains("still need to write [routines](memory/routines.md)"))
        #expect(index.contains("- [Kept](memory/kept.md) — the plain entry"))
        // And nothing was added: kept.md is already mentioned, twice.
        #expect(index.components(separatedBy: "memory/kept.md").count - 1 == 2)
    }

    /// Repeated reconciliation must converge. It did not when a filename could
    /// contain a `)`: the generated line parsed back as a different path, so
    /// every write appended another copy of it.
    @Test func reconcilingIsIdempotentAcrossRepeatedWrites() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for _ in 0..<4 {
            try AssistantMemory.write(
                home: home, path: "memory/notes.md", contents: "# Notes\n\nA fact.\n", append: false
            )
            try AssistantMemory.write(
                home: home, path: "memory/other.md", contents: "# Other\n\nAnother.\n", append: false
            )
        }
        let index = AssistantMemory.readIndex(home: home)

        #expect(index.components(separatedBy: "memory/notes.md").count - 1 == 1)
        #expect(index.components(separatedBy: "memory/other.md").count - 1 == 1)
    }

    /// A name that cannot survive a round trip through a markdown link cannot
    /// be indexed, so it is refused at the door rather than left to rot there.
    @Test func rejectsNamesThatWouldBreakTheIndexLink() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for name in ["notes(1).md", "my notes.md", "notes[a].md", "notes\u{7}.md"] {
            #expect(throws: AssistantMemoryError.self) {
                try AssistantMemory.write(
                    home: home, path: "memory/\(name)", contents: "x", append: false
                )
            }
        }
        try AssistantMemory.write(
            home: home, path: "memory/kaguya-notes_2.md", contents: "# Ok\n\nA fact.\n", append: false
        )
        #expect(AssistantMemory.readIndex(home: home).contains("memory/kaguya-notes_2.md"))
    }

    /// Without this the prompt keeps offering a topic that no longer exists,
    /// and the assistant keeps trying to ReadMemory it.
    @Test func deletingATopicRemovesItsFileAndItsIndexLine() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try AssistantMemory.write(
            home: home, path: "memory/stale.md", contents: "# Stale\n\nOld plan.\n", append: false
        )
        #expect(AssistantMemory.readIndex(home: home).contains("memory/stale.md"))

        try AssistantMemory.delete(home: home, path: "memory/stale.md")

        #expect(!AssistantMemory.readIndex(home: home).contains("memory/stale.md"))
        #expect(!AssistantMemory.listingText(home: home).contains("memory/stale.md"))
        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.delete(home: home, path: "memory/stale.md")
        }
    }

    /// The index is the map to everything else; deleting it would strand every
    /// topic file the assistant has ever written.
    @Test func theIndexItselfCannotBeDeleted() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(throws: AssistantMemoryError.self) {
            try AssistantMemory.delete(home: home, path: "MEMORY.md")
        }
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent("MEMORY.md").path
        ))
    }

    /// A home whose memory directory has not been created yet must not be read
    /// as "every topic file is gone" — that would empty a good index.
    @Test func reconcilingWithoutAMemoryDirectoryLeavesTheIndexAlone() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "MEMORY.md", "# Memory index\n\n- [Projects](memory/projects.md) — why\n")

        try AssistantMemory.refreshIndex(home: home)

        #expect(AssistantMemory.readIndex(home: home).contains("memory/projects.md"))
    }

    // MARK: - Recall

    /// The point of the whole phase: the facts that should colour every answer
    /// arrive in the prompt, not behind a tool call the lean assistant model
    /// mostly declines to make.
    @Test func recallCarriesPreferencesAndRelationsInFull() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "memory/preferences.md", """
            # Preferences

            - Ships with squash merges, never a merge commit.

            """)
        try seed(home, "memory/relations.md", """
            # Project relations

            - kaguya ⇄ kailash: kaguya's web client calls kailash's API. \
            Contract: `api/routes.ts`. Learned: user said so.

            """)
        try seed(home, "memory/deep-notes.md", "# Deep notes\n\nA long aside.\n")

        let digest = AssistantMemory.recallDigest(home: home)

        #expect(digest.contains("squash merges"))
        #expect(digest.contains("api/routes.ts"))
        #expect(digest.contains("MEMORY.md"))
        // Not a recall file: it stays behind ReadMemory so the prompt keeps a
        // fixed cost as memory grows.
        #expect(!digest.contains("A long aside"))
    }

    /// A first-run home teaches the model only that memory is empty — which
    /// the empty index already says, at a fraction of the tokens.
    @Test func recallSkipsFilesThatAreStillTheirSeed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "memory/preferences.md", "# Preferences\n\nNothing recorded yet.\n")
        try seed(home, "memory/relations.md", "# Project relations\n\nNothing recorded yet.\n")

        let digest = AssistantMemory.recallDigest(home: home)

        #expect(!digest.contains("Nothing recorded yet"))
        #expect(digest.contains("One line per memory file."))
    }

    /// A file whose facts are written as headings is a file with facts in it.
    /// Stripping every `#` line to find the body classified it as a seed and
    /// dropped exactly the memory the digest exists to carry.
    @Test func recallKeepsAFileWhoseFactsAreWrittenAsHeadings() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "memory/preferences.md", """
            # Preferences

            ## Harness
            Codex for Rust, Claude for Swift.

            """)

        #expect(AssistantMemory.recallDigest(home: home).contains("Codex for Rust"))
    }

    @Test func recallStaysInsideItsBudgetAndSaysWhereItStopped() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let long = (1...400).map { "- preference number \($0) about how things are done" }
            .joined(separator: "\n")
        try seed(home, "memory/preferences.md", "# Preferences\n\n\(long)\n")

        let digest = AssistantMemory.recallDigest(home: home, budget: 1_200)

        #expect(digest.count <= 1_200)
        #expect(digest.contains("preference number 1 "))
        #expect(digest.contains("clipped"))
        // Clipped on a line boundary, so no fact is cut mid-sentence.
        #expect(!digest.contains("- preference number 400 about how"))
    }

    /// The index is the map to everything not recalled in full, so it keeps
    /// its reserved share — but it cannot spend the whole budget either.
    @Test func recallHoldsItsBudgetWhenTheIndexAloneIsHuge() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "MEMORY.md", "# Memory index\n\n"
            + (1...500).map { "- [Topic \($0)](memory/topic-\($0).md) — a hook" }
                .joined(separator: "\n"))
        try seed(home, "memory/preferences.md", "# Preferences\n\nShips on Fridays.\n")

        // Including budgets too small to fit the "clipped" marker itself,
        // where appending it anyway would return more than was asked for.
        for budget in [1, 40, 84, 400, 2_000, AssistantMemory.defaultRecallBudget] {
            let digest = AssistantMemory.recallDigest(home: home, budget: budget)
            #expect(digest.count <= budget)
        }
        // Past the index's reserved share, the preferences still get in.
        #expect(AssistantMemory.recallDigest(home: home).contains("Ships on Fridays."))
    }

    @Test func recallIsEmptyForAHomeWithNoMemoryAtAll() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(AssistantMemory.recallDigest(home: home).isEmpty)
    }

    /// End to end: what the assistant's session is actually started with.
    @Test func theSystemPromptCarriesRecalledPreferences() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try seed(home, "memory/preferences.md", "# Preferences\n\nWants Codex for Rust work.\n")

        let prompt = AssistantPrompt.systemPrompt(home: home, workspaceID: WorkspaceID.generate())

        #expect(prompt.contains("Wants Codex for Rust work."))
        #expect(prompt.contains("memory/preferences.md"))
    }

    @Test func theSystemPromptOmitsTheMemoryBlockWhenThereIsNothingToRecall() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let prompt = AssistantPrompt.systemPrompt(home: home, workspaceID: WorkspaceID.generate())

        #expect(!prompt.contains("the index of everything you know"))
        // The identity is unconditional; only the memory block is not.
        #expect(prompt.contains("You are the ORE assistant"))
    }
}
