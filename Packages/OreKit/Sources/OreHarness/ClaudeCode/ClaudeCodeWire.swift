import Foundation
import OreProtocol

/// Wire types for Claude Code's `--output-format stream-json` protocol.
///
/// Decoding is deliberately lenient: unknown message types, unknown content
/// blocks and unknown fields are ignored rather than fatal. The CLI ships
/// weekly and adds fields constantly — a driver that rejects what it doesn't
/// recognize would break on every release.
enum ClaudeWire {
    // MARK: - Top-level envelope

    struct Envelope: Decodable {
        var type: String
        var subtype: String?
        var sessionID: String?
        var uuid: String?

        enum CodingKeys: String, CodingKey {
            case type
            case subtype
            case sessionID = "session_id"
            case uuid
        }
    }

    private static let typePrefix = Array(#"{"type":""#.utf8)

    /// The top-level `type` of a line, read without parsing it.
    ///
    /// The CLI writes `type` as the first key of every message, so a line that
    /// starts `{"type":"…"` names its type in the first few bytes — and a token
    /// delta is otherwise parsed twice, once for the envelope and once for the
    /// payload. Nil means "not in that shape, decode the envelope to find out",
    /// never "not a message".
    static func peekType(in line: String) -> Substring? {
        let bytes = line.utf8
        guard bytes.starts(with: typePrefix) else { return nil }
        let start = bytes.index(bytes.startIndex, offsetBy: typePrefix.count)
        guard let end = bytes[start...].firstIndex(where: { $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }),
              bytes[end] == UInt8(ascii: "\"")
        else { return nil }
        return Substring(bytes[start..<end])
    }

    // MARK: - system/init

    struct SystemInit: Decodable {
        var sessionID: String
        var cwd: String
        var model: String?
        var tools: [String]?
        var permissionMode: String?
        var claudeCodeVersion: String?
        var apiKeySource: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd
            case model
            case tools
            case permissionMode
            case claudeCodeVersion = "claude_code_version"
            case apiKeySource
        }
    }

    struct SystemStatus: Decodable {
        var status: String?
        var state: String?
    }

    /// Emitted when Claude Code auto-compacts its own context to stay under the
    /// window: `{"type":"system","subtype":"compact_boundary","compact_metadata":…}`.
    struct CompactBoundary: Decodable {
        var compactMetadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case compactMetadata = "compact_metadata"
        }

        struct Metadata: Decodable {
            var trigger: String?
            var preTokens: Int?

            enum CodingKeys: String, CodingKey {
                case trigger
                case preTokens = "pre_tokens"
            }
        }
    }

    /// `{"type":"system","subtype":"background_tasks_changed","tasks":[…]}` —
    /// every live background task after a start, completion or kill. The CLI
    /// documents replace semantics: swap the whole set for each payload.
    struct BackgroundTasksChanged: Decodable {
        var tasks: [Entry]

        struct Entry: Decodable {
            var taskID: String
            var taskType: String?
            var description: String?
            var ambient: Bool?

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
                case taskType = "task_type"
                case description
                case ambient
            }
        }
    }

    // MARK: - Assistant / user messages

    struct AssistantMessage: Decodable {
        var message: Message
        var parentToolUseID: String?

        enum CodingKeys: String, CodingKey {
            case message
            case parentToolUseID = "parent_tool_use_id"
        }

        struct Message: Decodable {
            var id: String?
            var model: String?
            var content: [ContentBlock]
            var usage: Usage?
        }
    }

    struct UserMessageEnvelope: Decodable {
        var message: Message
        var parentToolUseID: String?
        var toolUseResult: JSONValue?

        enum CodingKeys: String, CodingKey {
            case message
            case parentToolUseID = "parent_tool_use_id"
            case toolUseResult = "tool_use_result"
        }

        struct Message: Decodable {
            /// Either a plain string or an array of blocks — the CLI uses both.
            var content: [ContentBlock]

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                    content = blocks
                } else if let text = try? container.decode(String.self, forKey: .content) {
                    content = [ContentBlock(type: "text", text: text)]
                } else {
                    content = []
                }
            }

            enum CodingKeys: String, CodingKey {
                case content
            }
        }
    }

    /// One content block. Every field is optional because the shape depends on
    /// `type`, and we want an unknown type to decode successfully and be
    /// skipped rather than fail the whole message.
    struct ContentBlock: Decodable {
        var type: String
        var text: String?
        var thinking: String?
        // tool_use
        var id: String?
        var name: String?
        var input: JSONValue?
        // tool_result
        var toolUseID: String?
        var isError: Bool?
        var content: JSONValue?

        init(type: String, text: String? = nil) {
            self.type = type
            self.text = text
        }

        enum CodingKeys: String, CodingKey {
            case type, text, thinking, id, name, input
            case toolUseID = "tool_use_id"
            case isError = "is_error"
            case content
        }

        /// Flattens a `tool_result` payload, which may be a string or an array
        /// of text/image blocks, into displayable text.
        var flattenedResultText: String {
            guard let content else { return "" }
            switch content {
            case .string(let value):
                return value
            case .array(let blocks):
                return blocks.compactMap { block -> String? in
                    if let text = block["text"]?.stringValue { return text }
                    if case .string(let value) = block { return value }
                    if block["type"]?.stringValue == "image" { return "[image]" }
                    return nil
                }.joined(separator: "\n")
            default:
                return content.description
            }
        }
    }

    struct Usage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }

    // MARK: - stream_event (raw model SSE, passed through by the CLI)

    struct StreamEvent: Decodable {
        var event: Event
        var parentToolUseID: String?

        enum CodingKeys: String, CodingKey {
            case event
            case parentToolUseID = "parent_tool_use_id"
        }

        struct Event: Decodable {
            var type: String
            var index: Int?
            var contentBlock: ContentBlock?
            var delta: Delta?
            var message: MessageStart?

            enum CodingKeys: String, CodingKey {
                case type, index, delta, message
                case contentBlock = "content_block"
            }
        }

        struct Delta: Decodable {
            var type: String?
            var text: String?
            var thinking: String?
            var partialJSON: String?
            var stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking
                case partialJSON = "partial_json"
                case stopReason = "stop_reason"
            }
        }

        struct MessageStart: Decodable {
            var id: String?
            var model: String?
        }
    }

    // MARK: - result

    struct Result: Decodable {
        var subtype: String?
        var isError: Bool?
        var result: String?
        var sessionID: String?
        var durationMS: Int?
        var totalCostUSD: Double?
        var usage: Usage?
        var modelUsage: [String: ModelUsage]?
        var terminalReason: String?

        enum CodingKeys: String, CodingKey {
            case subtype
            case isError = "is_error"
            case result
            case sessionID = "session_id"
            case durationMS = "duration_ms"
            case totalCostUSD = "total_cost_usd"
            case usage
            case modelUsage
            case terminalReason = "terminal_reason"
        }

        struct ModelUsage: Decodable {
            var contextWindow: Int?
        }
    }

    struct RateLimitEvent: Decodable {
        var rateLimitInfo: Info?

        enum CodingKeys: String, CodingKey {
            case rateLimitInfo = "rate_limit_info"
        }

        struct Info: Decodable {
            var status: String?
            var resetsAt: Double?
            var rateLimitType: String?

            enum CodingKeys: String, CodingKey {
                case status
                case resetsAt
                case rateLimitType
            }
        }
    }

    // MARK: - Control protocol (bidirectional)

    /// CLI → ORE. The CLI blocks on our reply, so every one of these must be
    /// answered — including with a denial when the user walks away.
    struct ControlRequest: Decodable {
        var requestID: String
        var request: Payload

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case request
        }

        struct Payload: Decodable {
            var subtype: String
            var toolName: String?
            var displayName: String?
            var description: String?
            var input: JSONValue?
            var toolUseID: String?
            var permissionSuggestions: [JSONValue]?

            enum CodingKeys: String, CodingKey {
                case subtype
                case toolName = "tool_name"
                case displayName = "display_name"
                case description
                case input
                case toolUseID = "tool_use_id"
                case permissionSuggestions = "permission_suggestions"
            }
        }
    }

    /// ORE → CLI, in reply to a `ControlRequest`.
    struct ControlResponse: Encodable {
        var type = "control_response"
        var response: Body

        struct Body: Encodable {
            var subtype: String
            var requestID: String
            var response: JSONValue?
            var error: String?

            enum CodingKeys: String, CodingKey {
                case subtype
                case requestID = "request_id"
                case response
                case error
            }
        }

        static func success(requestID: String, payload: JSONValue) -> ControlResponse {
            ControlResponse(
                response: Body(subtype: "success", requestID: requestID, response: payload)
            )
        }
    }

    /// ORE → CLI. Interrupt, permission-mode changes and the initial handshake.
    struct ControlRequestOutbound: Encodable {
        var type = "control_request"
        var requestID: String
        var request: JSONValue

        enum CodingKeys: String, CodingKey {
            case type
            case requestID = "request_id"
            case request
        }
    }

    /// CLI → ORE, acknowledging one of our control requests.
    struct ControlResponseInbound: Decodable {
        var response: Body

        struct Body: Decodable {
            var subtype: String
            var requestID: String
            var error: String?

            enum CodingKeys: String, CodingKey {
                case subtype
                case requestID = "request_id"
                case error
            }
        }
    }

    /// ORE → CLI. A user turn, in the Anthropic message shape the CLI expects.
    struct UserInputMessage: Encodable {
        var type = "user"
        var message: Body

        struct Body: Encodable {
            var role = "user"
            var content: [TextBlock]
        }

        struct TextBlock: Encodable {
            var type = "text"
            var text: String
        }

        init(text: String) {
            message = Body(content: [TextBlock(text: text)])
        }
    }

    /// What to do with an inbound `control_request` line.
    ///
    /// `can_use_tool` is answered by the UI. Everything else — including a
    /// payload we cannot decode — must get an error reply, or the CLI waits
    /// forever with no card on screen.
    enum InboundControl: Equatable {
        case none
        case permissionPrompt
        case unsupported(requestID: String, subtype: String?)
    }

    static func inboundControl(in line: String) -> InboundControl {
        // Every stdout line comes through here; the peek settles almost all of
        // them without scanning a multi-megabyte tool result for the marker.
        if let type = peekType(in: line) {
            guard type == "control_request" else { return .none }
        } else {
            guard line.contains("\"control_request\"") else { return .none }
        }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "control_request"
        else { return .none }

        let requestID = json["request_id"] as? String
        let subtype = (json["request"] as? [String: Any])?["subtype"] as? String
        if subtype == "can_use_tool",
           requestID != nil,
           (try? JSONDecoder().decode(ControlRequest.self, from: data)) != nil {
            return .permissionPrompt
        }
        guard let requestID else { return .none }
        return .unsupported(requestID: requestID, subtype: subtype)
    }
}
