import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns the agent's reading-shaped output into speaking-shaped sentences.
///
/// The transcript is written to be read: exhaustive, structured, full of
/// paths and code. Narration needs the opposite — one or two sentences about
/// what is happening now — and that compression is a language task, so it
/// runs on Apple's on-device model (macOS 26), same as `VoiceIntentRefiner`:
/// free, private, on the ANE, and fast enough to keep up with a live turn.
/// Where the model is unavailable the engine falls back to templates alone.
@MainActor
final class NarrationSummarizer {
    /// The only telemetry this feature has: whether the model exists on this
    /// machine, and how each call went. `log stream --predicate 'category ==
    /// "Narration"'` is the way to answer "is the summarizer actually firing".
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ore.OreMac",
        category: "Narration"
    )

    /// Type-erased so the class compiles on OS versions without the framework.
    private var sessionBox: Any?
    private var loggedAvailability = false
    /// Lightweight health counters for tuning; the log carries the detail.
    private(set) var attempts = 0
    private(set) var timeouts = 0

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why the model can or can't run here, as one sentence the settings pane
    /// can show — the difference between "narration is dumb" and "turn on
    /// Apple Intelligence" is exactly this string.
    var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Ready"
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings"
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading"
            case .unavailable:
                return "Unavailable right now"
            }
        }
        #endif
        return "Requires macOS 26"
    }

    /// Loads the model before the first digest, so narration doesn't open
    /// with a cold-start silence.
    func prewarm() {
        if !loggedAvailability {
            loggedAvailability = true
            Self.log.info("summarizer availability: \(self.availabilityDescription, privacy: .public)")
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return }
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        sessionBox = session
        #endif
    }

    /// One or two spoken sentences for the agent's recent thinking and
    /// activity, or nil when there's nothing new worth saying (also the
    /// answer on timeout — a late summary is a stale summary).
    func digest(_ prompt: String) async -> String? {
        await respond(to: "What should the user hear right now?\n\n\(prompt)")
    }

    /// The end-of-turn report, compressed for the ear.
    func compress(finalReport: String) async -> String? {
        await respond(to: """
            The agent just finished its turn. Compress its final report into \
            one or two short spoken sentences telling the user what was done \
            and anything they must know.

            Final report:
            \(finalReport)
            """)
    }

    /// One spoken sentence saying what a proposed plan would do, so the
    /// "come look at this" interrupt carries the crux and not just the event.
    func planCrux(_ markdown: String) async -> String? {
        await respond(to: """
            The agent just proposed a plan and is waiting for the user's \
            approval. In one short spoken sentence, say what the plan would do.

            Plan:
            \(String(markdown.prefix(2000)))
            """)
    }

    private func respond(to prompt: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return nil }
        let session = (sessionBox as? LanguageModelSession)
            ?? LanguageModelSession(instructions: Self.instructions)
        // Sessions accumulate history; a fresh one per call keeps context and
        // latency flat, and prewarming the next means it's warm before the
        // next digest triggers.
        sessionBox = nil
        attempts += 1
        let startedAt = Date()
        defer { prewarm() }

        // A race, not a wait: narration describes now, so a slow response is
        // abandoned rather than spoken late. Mirrors `VoiceIntentRefiner`,
        // including not awaiting the losing task — a hung `respond` may not
        // honor cancellation.
        let parse = await withCheckedContinuation { (continuation: CheckedContinuation<NarrationParse?, Never>) in
            let gate = RaceGate()
            let work = Task { @MainActor in
                let value = try? await session.respond(
                    to: prompt,
                    generating: NarrationParse.self,
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
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard let parse else {
            timeouts += 1
            Self.log.info("summarizer gave nothing (timeout or error) after \(elapsedMS)ms")
            return nil
        }
        guard parse.worthSpeaking else {
            Self.log.debug("summarizer declined in \(elapsedMS)ms")
            return nil
        }
        let sentence = NarrationPhraser.sanitize(parse.sentence)
        Self.log.debug("summarizer spoke in \(elapsedMS)ms")
        return sentence.isEmpty ? nil : sentence
        #else
        return nil
        #endif
    }

    private static let instructions = """
        You narrate a coding agent's work aloud to its user, who is listening \
        rather than reading. Given the agent's recent reasoning, output, and \
        tool activity, produce one or two short spoken sentences: what the \
        agent is doing now and, when it's clear, what comes next or what the \
        user must know. Present tense, plain spoken language, addressed to \
        the user. No code syntax, no file paths — plain file names only. \
        Never repeat what was last spoken. If nothing new is worth saying, \
        set worthSpeaking to false.
        """
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
private struct NarrationParse {
    @Guide(description: "One or two short spoken sentences about what the agent is doing now, for the user to hear.")
    var sentence: String
    @Guide(description: "True only if there is something new worth speaking aloud.")
    var worthSpeaking: Bool
}
#endif
