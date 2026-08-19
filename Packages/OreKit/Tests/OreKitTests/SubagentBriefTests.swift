import Foundation
import Testing

@testable import OreProtocol

/// The one line a transcript row shows for a spawned subagent. It is pulled
/// straight out of the brief rather than summarized, so the cleaning rules are
/// the whole of the quality.
struct SubagentBriefTests {
    private func purpose(_ prompt: String, description: String? = nil) -> String? {
        var input: [String: JSONValue] = ["prompt": .string(prompt)]
        if let description { input["description"] = .string(description) }
        return SubagentBrief.purpose(from: .object(input))
    }

    @Test func theOpeningSentenceIsTheAsk() {
        #expect(
            purpose("Find how sub-agents are displayed in the UI. Report file paths and lines.")
                == "Find how sub-agents are displayed in the UI."
        )
    }

    @Test func aSentenceBoundaryTooEarlyToBeOneIsIgnored() {
        // "e.g." ends a clause, not the ask — and a file extension is not a
        // full stop at all.
        #expect(
            purpose("Rename e.g. the stale flags in TranscriptView.swift and then stop.")
                == "Rename e.g. the stale flags in TranscriptView.swift and then stop."
        )
    }

    @Test func markdownAndListMarkersAreFlattened() {
        #expect(purpose("## Goal\nMap the `harness` abstraction end to end.")
            == "Map the harness abstraction end to end.")
        #expect(purpose("1. Audit every **translator** for nesting support.")
            == "Audit every translator for nesting support.")
    }

    @Test func aLeadingScopingClauseIsDropped() {
        #expect(
            purpose("In this repo (/Users/x/ore), explore the sidebar and report back.")
                == "Explore the sidebar and report back."
        )
        // Only when it really is a scope — an ordinary sentence starting with
        // "In" keeps its opening.
        #expect(
            purpose("In practice, the parser drops nested events. Explain why.")
                == "In practice, the parser drops nested events."
        )
    }

    @Test func aLongBriefIsElidedOnAWordBoundary() {
        let line = purpose(String(repeating: "delegate ", count: 60))
        #expect(line!.count <= 161)
        // Cut on a word boundary, never mid-word.
        #expect(line!.hasSuffix("delegate…"))
    }

    @Test func aFragmentFallsBackToTheLabel() {
        #expect(purpose("Context:", description: "Review the diff") == "Review the diff")
    }

    @Test func aBriefThatOnlyRestatesTheChipIsSuppressed() {
        let input = JSONValue.object([
            "description": .string("Review the diff"),
            "prompt": .string("Review the diff."),
        ])
        #expect(SubagentBrief.purpose(from: input, distinctFrom: "Review the diff") == nil)
        #expect(SubagentBrief.purpose(from: input, distinctFrom: "Something else") != nil)
    }

    @Test func handoffToolsAreRecognisedAcrossHarnesses() {
        for name in ["task", "Task", "agent", "mcp__ore__task", "spawn_agent", "run_subagent"] {
            #expect(SubagentBrief.isSubagentTool(name), "\(name) should be a handoff")
        }
        for name in ["TaskCreate", "TaskUpdate", "Bash", "Read", "todowrite"] {
            #expect(!SubagentBrief.isSubagentTool(name), "\(name) should not be a handoff")
        }
    }

    @Test func aliasesAreCopiedOntoTheCanonicalKeysWithoutLosingTheOriginals() {
        let normalized = SubagentBrief.normalized(.object([
            "instructions": .string("Check the tests."),
            "title": .string("Test sweep"),
            "agentType": .string("reviewer"),
        ]))
        #expect(SubagentBrief.brief(from: normalized) == "Check the tests.")
        #expect(SubagentBrief.label(from: normalized) == "Test sweep")
        #expect(SubagentBrief.agentType(from: normalized) == "reviewer")
        // A permission response hands the input back to the CLI verbatim, so
        // the keys it sent must survive.
        #expect(normalized["instructions"]?.stringValue == "Check the tests.")
    }

    @Test func canonicalKeysWin() {
        let normalized = SubagentBrief.normalized(.object([
            "prompt": .string("The real brief."),
            "instructions": .string("A stale alias."),
        ]))
        #expect(SubagentBrief.brief(from: normalized) == "The real brief.")
    }
}
