import Foundation
import Testing

@testable import OreProtocol

/// The thinking chip has to name the page or the query, and every harness
/// spells those fields differently. These cases are the shapes we have seen
/// on the wire, not a guess at a unified schema.
struct ToolWebActivityTests {
    @Test func claudeWebFetchReadsUrl() {
        let activity = ToolWebActivity.classify(
            tool: "WebFetch",
            input: .object(["url": .string("https://docs.python.org/3/library/os.html"), "prompt": .string("sum")])
        )
        #expect(activity?.kind == .fetch)
        #expect(activity?.subject == "https://docs.python.org/3/library/os.html")
        #expect(activity?.chipLabel == "docs.python.org/3/library/os.html")
    }

    @Test func claudeWebSearchReadsQueryAndIsNotAFetch() {
        let activity = ToolWebActivity.classify(
            tool: "WebSearch",
            input: .object(["query": .string("perco sd paper")])
        )
        #expect(activity?.kind == .search)
        #expect(activity?.chipLabel == "perco sd paper")
    }

    @Test func cursorTargetUrlIsPromotedToUrl() {
        let input = ToolWebActivity.normalized(.object([
            "targetUrl": .string("https://www.github.com/openai/codex"),
        ]))
        #expect(input["url"]?.stringValue == "https://www.github.com/openai/codex")
        let activity = ToolWebActivity.classify(tool: "WebFetch", input: input)
        #expect(activity?.chipLabel == "github.com/openai/codex")
    }

    @Test func codexOpenPageIsAFetchEvenWhenTheItemIsNamedWebSearch() {
        let activity = ToolWebActivity.classify(
            tool: "webSearch",
            input: .object([
                "action": .object([
                    "type": .string("open_page"),
                    "url": .string("https://platform.openai.com/docs/guides/tools"),
                ]),
            ])
        )
        #expect(activity?.kind == .fetch)
        #expect(activity?.subject == "https://platform.openai.com/docs/guides/tools")
    }

    @Test func codexSearchActionKeepsTheQuery() {
        let activity = ToolWebActivity.classify(
            tool: "webSearch",
            input: .object([
                "query": .string("swift jsonvalue lossless integer"),
                "action": .object(["type": .string("search"), "query": .string("swift jsonvalue lossless integer")]),
            ])
        )
        #expect(activity?.kind == .search)
        #expect(activity?.subject == "swift jsonvalue lossless integer")
    }

    @Test func mcpFetchArgumentsAndServerNameAreNotConfused() {
        let activity = ToolWebActivity.classify(
            tool: "mcp__exa__web_fetch",
            input: .object(["urls": .array([.string("https://exa.ai/blog")])]),
            fallback: "exa"
        )
        #expect(activity?.kind == .fetch)
        #expect(activity?.subject == "https://exa.ai/blog")
        #expect(activity?.chipLabel != "exa")
    }

    @Test func jsonStringArgumentsAreUnwrapped() {
        let activity = ToolWebActivity.classify(
            tool: "fetch",
            input: .string(#"{"url":"https://example.com/a"}"#)
        )
        #expect(activity?.subject == "https://example.com/a")
    }

    @Test func nestedJsonStringArgumentsAreUnwrapped() {
        let activity = ToolWebActivity.classify(
            tool: "mcp__browser__web_fetch",
            input: .object([
                "arguments": .string(#"{"url":"https://example.com/nested"}"#),
            ]),
            fallback: "browser"
        )
        #expect(activity?.kind == .fetch)
        #expect(activity?.subject == "https://example.com/nested")
        #expect(activity?.chipLabel == "example.com/nested")
    }

    @Test func aBareToolNameIsNotUsedAsTheChip() {
        let activity = ToolWebActivity.classify(
            tool: "WebFetch",
            input: .object([:]),
            fallback: "WebFetch"
        )
        #expect(activity?.kind == .fetch)
        #expect(activity?.subject == nil)
        #expect(activity?.chipLabel == nil)
    }

    @Test func grepIsNotAWebSearch() {
        #expect(
            ToolWebActivity.classify(
                tool: "Grep",
                input: .object(["pattern": .string("TODO")])
            ) == nil
        )
    }

    @Test func aFetchNamedToolWithOnlyAQueryIsASearch() {
        let activity = ToolWebActivity.classify(
            tool: "web",
            input: .object(["query": .string("swift thinking chips")])
        )
        #expect(activity?.kind == .search)
        #expect(activity?.subject == "swift thinking chips")
    }
}
