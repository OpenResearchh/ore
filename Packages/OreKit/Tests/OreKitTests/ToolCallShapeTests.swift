import Foundation
import Testing

@testable import OreProtocol

struct ToolCallShapeTests {
    @Test func antigravityNamesMapOntoClaudeStyleNames() {
        #expect(ToolCallShape.canonicalName("view_file") == "Read")
        #expect(ToolCallShape.canonicalName("write_to_file") == "Write")
        #expect(ToolCallShape.canonicalName("replace_file_content") == "Edit")
        #expect(ToolCallShape.canonicalName("run_command") == "Bash")
        #expect(ToolCallShape.canonicalName("grep_search") == "Grep")
        #expect(ToolCallShape.canonicalName("find_by_name") == "Glob")
        #expect(ToolCallShape.canonicalName("list_dir") == "LS")
        #expect(ToolCallShape.canonicalName("search_web") == "WebSearch")
        #expect(ToolCallShape.canonicalName("read_url_content") == "WebFetch")
        #expect(ToolCallShape.canonicalName("invoke_subagent") == "Task")
        #expect(ToolCallShape.canonicalName("Read") == "Read")
        #expect(ToolCallShape.canonicalName("wait") == "Wait")
        #expect(ToolCallShape.canonicalName("wait_5_seconds") == "Wait")
        #expect(ToolCallShape.canonicalName("generate_image") == "GenerateImage")
        #expect(ToolCallShape.canonicalName("capture_browser_screenshot") == "Screenshot")
        #expect(ToolCallShape.canonicalName("command_status") == "BashOutput")
        #expect(ToolCallShape.canonicalName("sed_file") == "Edit")
        #expect(ToolCallShape.canonicalName("open_browser_url") == "WebFetch")
        #expect(ToolCallShape.isBrowser("browser_click_element"))
        #expect(!ToolCallShape.isBrowser("open_browser_url"))
        #expect(ToolCallShape.isWait("wait_5_seconds"))
    }

    @Test func absolutePathAndCommandLineAreCopiedOntoCanonicalKeys() {
        let read = ToolCallShape.normalized(
            .object(["AbsolutePath": .string("/tmp/sample.txt")]),
            tool: "view_file"
        )
        #expect(read["file_path"]?.stringValue == "/tmp/sample.txt")
        #expect(ToolCallShape.filePath(in: read) == "/tmp/sample.txt")

        let bash = ToolCallShape.normalized(
            .object(["CommandLine": .string("echo PONG")]),
            tool: "run_command"
        )
        #expect(bash["command"]?.stringValue == "echo PONG")
        #expect(bash["CommandLine"]?.stringValue == "echo PONG")

        let grep = ToolCallShape.normalized(
            .object(["Query": .string("hello")]),
            tool: "grep_search"
        )
        #expect(grep["pattern"]?.stringValue == "hello")

        let camel = ToolCallShape.normalized(
            .object(["absolutePath": .string("/tmp/camel.txt")]),
            tool: "view_file"
        )
        #expect(ToolCallShape.filePath(in: camel) == "/tmp/camel.txt")

        let click = ToolCallShape.normalized(
            .object(["Selector": .string("#submit")]),
            tool: "browser_click_element"
        )
        #expect(click["selector"]?.stringValue == "#submit")
        #expect(ToolCallShape.chipSubject(tool: "browser_click_element", input: click) == "#submit")

        let wait = ToolCallShape.normalized(
            .object(["WaitMs": .integer(2500)]),
            tool: "wait"
        )
        #expect(ToolCallShape.waitLabel(from: wait, tool: "wait") == "2s")

        let mcp = ToolCallShape.resolvedName(
            "call_mcp_tool",
            input: .object([
                "ServerName": .string("github"),
                "ToolName": .string("get_issue"),
            ])
        )
        #expect(mcp == "mcp__github__get_issue")
    }

    @Test func antigravityReadErrorsDropThePermissionDump() {
        let dump = """
        declaring permissions: cortex tool view_file: convert tool call \
        for permissions: model output error: invalid tool call error \
        (invalid_args) failed to read file: stat /tmp/Agent.swift: \
        no such file or directory
        """
        #expect(ToolCallShape.filePath(inError: dump) == "/tmp/Agent.swift")
        #expect(
            ToolCallShape.sanitizedError(dump)
            == "No such file or directory: Agent.swift"
        )
    }

    @Test func finishIsHiddenBookkeeping() {
        #expect(ToolCallShape.isHidden("finish"))
        #expect(!ToolCallShape.isHidden("view_file"))
    }
}
