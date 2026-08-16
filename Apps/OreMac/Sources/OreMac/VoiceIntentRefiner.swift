import Foundation
import OreProtocol
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - File candidate ranking (pure, testable)

/// Picks which workspace files are worth offering to the language model as
/// tag candidates. The model gets a short list, not the whole tree — both for
/// prompt size and because a fuzzy token overlap already rules out almost
/// everything.
enum VoiceFileCandidates {
    struct Candidate: Equatable, Sendable {
        var name: String
        var path: String
    }

    /// Files whose name shares words with the transcript, best matches first.
    /// "look at the chat pane file" → ChatPane.swift scores 2 (chat, pane).
    static func rank(
        transcript: String,
        files: [Candidate],
        limit: Int = 20
    ) -> [Candidate] {
        let spokenWords = Set(words(in: transcript).filter { $0.count >= 3 })
        guard !spokenWords.isEmpty else { return [] }

        let scored: [(candidate: Candidate, score: Int)] = files.compactMap { file in
            let nameWords = Set(words(in: file.name))
            let overlap = nameWords.intersection(spokenWords)
            guard !overlap.isEmpty else { return nil }
            // Weight longer matched words: "pane" says more than "the".
            let score = overlap.reduce(0) { $0 + $1.count }
            return (file, score)
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.candidate)
    }

    /// Lowercased word split that also breaks camelCase and separators, so
    /// "ChatPane.swift" yields ["chat", "pane", "swift"].
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for ch in text {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && previousWasLower {
                    if !current.isEmpty { words.append(current) }
                    current = ""
                }
                current.append(Character(ch.lowercased()))
                previousWasLower = ch.isLowercase
            } else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

// MARK: - On-device refinement

/// Second-stage understanding for dictation. The regex/alias extractor stays
/// for instant chip feedback on every partial; this arbitrates the final
/// commit with Apple's on-device foundation model (macOS 26), which catches
/// what pattern matching can't — fuzzy file references ("the chat pane
/// file"), indirect settings requests — and produces the cleaned prompt with
/// command phrases removed. One call per voice session, right before send,
/// so its ~100–300 ms cost never touches the live transcript path.
///
/// Deliberately NOT a bundled third-party model (Gemma/MLX or similar): for
/// constrained structured extraction the system model is equally capable,
/// ships with the OS (no 1.5 GB of weights in the app), runs on the ANE, and
/// keeps audio-derived text entirely on device. A bundled model would have to
/// be significantly faster *and* better to justify that cost, and it isn't.
@MainActor
final class VoiceIntentRefiner {
    static let shared = VoiceIntentRefiner()

    struct Refinement: Equatable, Sendable {
        var cleanedPrompt: String?
        var modelID: String?
        var effort: ReasoningEffort?
        var mode: PermissionMode?
        var files: [VoiceFileCandidates.Candidate] = []
    }

    /// Type-erased so the class compiles on OS versions without the framework.
    private var sessionBox: Any?

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Loads the model while the user is still talking, so the commit-time
    /// call doesn't pay the cold start.
    func prewarm() {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return }
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        sessionBox = session
        #endif
    }

    func refine(
        spoken: String,
        catalog: VoiceSettingsCatalog,
        fileCandidates: [VoiceFileCandidates.Candidate]
    ) async -> Refinement? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return nil }
        let session = (sessionBox as? LanguageModelSession)
            ?? LanguageModelSession(instructions: Self.instructions)
        // Sessions accumulate history; one commit call per session keeps the
        // context (and latency) flat. The next dictation prewarms a fresh one.
        sessionBox = nil

        let prompt = Self.prompt(spoken: spoken, catalog: catalog, candidates: fileCandidates)
        // The turn is about to send; a stuck model must not hold it hostage.
        // This is a true race: whichever of {response, deadline} lands first
        // resolves the call, and a hung `respond` — which may not honor
        // cancellation, e.g. while compiling the guided-generation schema on
        // first use — is abandoned, never awaited.
        let parse = await withCheckedContinuation { (continuation: CheckedContinuation<VoiceParse?, Never>) in
            let gate = RaceGate()
            let work = Task { @MainActor in
                let value = try? await session.respond(
                    to: prompt,
                    generating: VoiceParse.self,
                    options: GenerationOptions(temperature: 0.0)
                ).content
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                if gate.claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let parse else { return nil }

        // The model is prompted with exact identifiers, but everything it
        // returns is still validated against the catalog — an invented model
        // ID or file path is dropped, never applied.
        let model = parse.modelID.flatMap { id in catalog.models.first { $0.id == id }?.id }
        let effort = parse.effort.flatMap { raw in
            catalog.efforts.first { $0.rawValue == raw.lowercased() }
        }
        let mode = parse.permissionMode.flatMap { raw in
            catalog.modes.first { $0.rawValue.lowercased() == raw.lowercased() }
        }
        let files = (parse.files ?? []).compactMap { path in
            fileCandidates.first { $0.path == path }
        }
        let cleaned = parse.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return Refinement(
            cleanedPrompt: cleaned.isEmpty ? nil : cleaned,
            modelID: model,
            effort: effort,
            mode: mode,
            files: files
        )
        #else
        return nil
        #endif
    }

    private static let instructions = """
        You clean up dictated prompts for a coding agent. The user speaks a \
        prompt that may embed spoken commands: switching the model, changing \
        reasoning effort or permission mode, or referring to workspace files. \
        Extract those commands and remove their phrasing from the prompt; \
        keep every other word exactly as spoken. Never invent identifiers: \
        only use values from the lists given in the request. If no command \
        was spoken, return the prompt unchanged and omit the other fields.
        """

    private static func prompt(
        spoken: String,
        catalog: VoiceSettingsCatalog,
        candidates: [VoiceFileCandidates.Candidate]
    ) -> String {
        var lines: [String] = []
        lines.append("Dictated text:")
        lines.append("\"\(spoken)\"")
        lines.append("")
        lines.append("Available model ids:")
        for model in catalog.models {
            lines.append("- \(model.id) (\(model.displayName), \(model.harness.rawValue))")
        }
        lines.append("Available reasoning efforts: "
            + catalog.efforts.map(\.rawValue).joined(separator: ", "))
        lines.append("Available permission modes: "
            + catalog.modes.map(\.rawValue).joined(separator: ", "))
        if !candidates.isEmpty {
            lines.append("Workspace file candidates (relative paths):")
            for file in candidates {
                lines.append("- \(file.path)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// First-caller-wins flag for racing a model response against its deadline.
private final class RaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True exactly once, for whichever side gets here first.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct VoiceParse {
    @Guide(description: "The dictated text with any spoken commands removed, otherwise unchanged. Empty if the entire dictation was commands.")
    var prompt: String
    @Guide(description: "Model id the user asked to switch to, exactly as listed. Omit if no model was mentioned.")
    var modelID: String?
    @Guide(description: "Reasoning effort the user asked for, exactly as listed. Omit if not mentioned.")
    var effort: String?
    @Guide(description: "Permission mode the user asked for, exactly as listed. Omit if not mentioned.")
    var permissionMode: String?
    @Guide(description: "Relative paths from the candidate list the user referred to. Omit if none.")
    var files: [String]?
}
#endif
