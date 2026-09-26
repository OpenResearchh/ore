import Foundation
import Testing

@testable import OreProtocol

struct ToolMCPActivityTests {
    @Test func anORECommentNamesTheFile() {
        let activity = ToolMCPActivity.classify(
            tool: "mcp__ore__PostDiffComment",
            input: .object([
                "filePath": .string("Apps/OreMac/TranscriptView.swift"),
                "startLine": .integer(12),
                "body": .string("This chip is blank."),
            ]),
            fallback: "ore"
        )
        #expect(activity?.title == "Comment")
        #expect(activity?.subject == "TranscriptView.swift")
        #expect(activity?.filePath == "Apps/OreMac/TranscriptView.swift")
        #expect(activity?.chipLabel != "ore")
    }

    @Test func aCommitNamesTheMessage() {
        let activity = ToolMCPActivity.classify(
            tool: "mcp__ore__Commit",
            input: .object(["message": .string("Fix fetch chips\n\nMore detail.")])
        )
        #expect(activity?.title == "Commit")
        #expect(activity?.subject == "Fix fetch chips")
    }

    @Test func aPullRequestNamesTheTitle() {
        let activity = ToolMCPActivity.classify(
            tool: "CreatePullRequest",
            input: .object(["title": .string("Show fetch URLs on thinking chips")])
        )
        #expect(activity?.title == "Pull request")
        #expect(activity?.subject == "Show fetch URLs on thinking chips")
    }

    @Test func githubIssueUsesOwnerRepoAndNumber() {
        let activity = ToolMCPActivity.classify(
            tool: "mcp__github__get_issue",
            input: .object([
                "owner": .string("openai"),
                "repo": .string("codex"),
                "issue_number": .integer(412),
            ]),
            fallback: "github"
        )
        #expect(activity?.title == "Issue")
        #expect(activity?.subject == "openai/codex#412")
        #expect(activity?.chipLabel != "github")
    }

    @Test func memoryNamesThePath() {
        let activity = ToolMCPActivity.classify(
            tool: "WriteMemory",
            input: .object(["path": .string("memory/voice.md"), "contents": .string("hold to talk")])
        )
        #expect(activity?.title == "Memory")
        #expect(activity?.subject == "voice.md")
    }

    @Test func skillReadsTheSkillName() {
        let activity = ToolMCPActivity.classify(
            tool: "Skill",
            input: .object(["skill": .string("pdf"), "args": .string("compress")])
        )
        #expect(activity?.title == "Skill")
        #expect(activity?.subject == "pdf")
    }

    @Test func aServerNameIsNotTheSubject() {
        let activity = ToolMCPActivity.classify(
            tool: "search_docs",
            input: .object(["title": .string("Indexes")]),
            fallback: "docs"
        )
        #expect(activity?.subject == "Indexes")
        #expect(activity?.chipLabel != "docs")
    }

    @Test func harnessPrimitivesAreLeftAlone() {
        #expect(ToolMCPActivity.classify(tool: "Glob", input: .object(["pattern": .string("*.swift")])) == nil)
        #expect(ToolMCPActivity.classify(tool: "Bash", input: .object(["command": .string("ls")])) == nil)
        #expect(ToolMCPActivity.classify(tool: "Grep", input: .object(["pattern": .string("TODO")])) == nil)
    }
}
