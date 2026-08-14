import Foundation
import OreProtocol

/// Replays a recorded `codex app-server` transcript through the driver's
/// translator, so CI can check the mapping without a CLI, a network or a plan.
public enum CodexTranscriptReplay {
    public static func events(
        transcript: String,
        sessionID: SessionID = SessionID(rawValue: "replay")
    ) -> [AgentEvent] {
        var translator = CodexTranslator(sessionID: sessionID)
        var events: [AgentEvent] = []

        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let method = message["method"]?.stringValue
            else { continue }

            // A server request rather than a notification: those become
            // permission requests and questions, which is the same mapping the
            // session performs.
            if let id = message["id"], !id.isNull {
                let requestID = id.stringValue ?? id.description
                if let permission = translator.permissionRequest(
                    method: method, params: message["params"], requestID: requestID
                ) {
                    events.append(.permissionRequest(permission))
                    continue
                }
                if method == "item/tool/requestUserInput" {
                    events += translator
                        .question(params: message["params"], requestID: requestID)
                        .map(AgentEvent.question)
                }
                continue
            }

            events += translator.translate(method: method, params: message["params"]).events
        }
        return events
    }
}
