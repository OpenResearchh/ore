import AppKit
import Foundation
import Observation
import OreProtocol

/// The global voice mode: hold ⇧⌥ anywhere, talk to the assistant, hear it
/// answer. App-level and headless — it never steals focus, never opens a
/// window, and works the same whether the user is in ORE, Safari, or a
/// terminal.
///
/// Owns its own `VoiceInputController` rather than borrowing a composer's:
/// the composer's dictation is per-pane state tied to what's on screen, and
/// the whole point of the assistant is that it isn't.
@MainActor
@Observable
final class VoiceAssistantController {
    /// Where the exchange is, for the floating HUD: nothing → mic open →
    /// waiting on the assistant → nothing again once the reply is spoken.
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        /// A short open mic right after a narrated confirmation, so "yes"
        /// doesn't need another chord.
        case answering
    }

    private(set) var phase: Phase = .idle {
        didSet { AssistantVoiceHUD.shared.phaseChanged(self) }
    }

    /// Whether the assistant's microphone is open.
    var isListening: Bool { phase == .listening }

    /// Live views into the recognizer, for the HUD's transcript tail and
    /// waveform. Reads register observation — `VoiceInputController` is
    /// `@Observable` — so the HUD animates without any forwarding.
    var liveTranscript: String { voice.transcript }
    var audioLevel: Double { voice.audioLevel }

    weak var model: AppModel?

    private let voice = VoiceInputController()
    private var startTask: Task<Void, Never>?
    private var stillWorkingTask: Task<Void, Never>?
    private var answerWindowTask: Task<Void, Never>?
    /// The user asked something by voice and hasn't heard back yet — the next
    /// assistant turn completion is spoken no matter what the ambient
    /// narration settings say.
    private var awaitingSpokenReply = false
    private var lastVoiceInteraction: Date?
    /// Milestone throttling: the last phrase spoken and when, so a burst of
    /// tool calls narrates as a beat, not a commentary track.
    private var lastMilestone: String?
    private var lastMilestoneAt: Date = .distantPast

    /// How long after a voice exchange a confirmation is still narrated (and
    /// answerable by voice). Matches the action policy's task-grant window —
    /// the same notion of "the user is still in this task".
    private static let voiceSessionWindow: TimeInterval = 15 * 60

    /// A reply slower than this earns one spoken nudge, so a long-running
    /// status query doesn't feel like the assistant went away.
    private static let stillWorkingDelay: Duration = .seconds(12)

    /// Minimum quiet between spoken milestones.
    private static let milestoneGap: TimeInterval = 5

    /// How long the hands-free answer mic stays open before giving up and
    /// leaving the confirmation to the window, the notification, or a chord.
    private static let answerWindow: Duration = .seconds(7)

    func handle(_ command: VoiceCommand) {
        guard command.target == .assistant else { return }
        switch command.kind {
        case .start: begin()
        case .stop: finish()
        case .toggle, .commit: break
        }
    }

    // MARK: - Microphone

    private func begin() {
        guard let model else { return }
        // A hold while the hands-free answer mic is open supersedes it — the
        // user reached for the chord, so give them the full session.
        if phase == .answering { closeAnswerWindow() }
        guard !voice.isActive else { return }
        startTask?.cancel()
        if model.narration.isMicActive {
            // A composer dictation owns the audio. Park its words in its
            // draft — never send something the user didn't finish — give the
            // recognizer a beat to let go, then take the microphone.
            VoiceHotkeyMonitor.shared.requestComposerCommit()
            startTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.openMic()
            }
        } else {
            openMic()
        }
    }

    private func openMic() {
        guard let model, !voice.isActive else { return }
        // Prime the recognizer with the names it will otherwise mangle.
        voice.vocabulary = projectNames()
        phase = .listening
        // Ducking: the assistant must not talk over the user, and its TTS
        // must not leak into the transcription.
        model.narration.setMicActive(true)
        voice.start()
    }

    /// The proper nouns of this user's world: workspace names and repository
    /// names — used both to bias recognition and to repair near-misses.
    private func projectNames() -> [String] {
        guard let model else { return [] }
        var names = model.workspaces.map(\.name)
        names += model.repositories.map { (($0 as NSString).lastPathComponent) }
        return names
    }

    private func finish() {
        startTask?.cancel()
        startTask = nil
        guard isListening else { return }
        let heard = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = VoiceVocabulary(names: projectNames()).corrected(heard)
        if voice.isActive { voice.stop() }
        model?.narration.setMicActive(false)

        guard let model, !spoken.isEmpty else {
            phase = .idle
            return
        }
        lastVoiceInteraction = Date()

        // A short yes/no while a confirmation is pending answers *it* rather
        // than becoming a message — this is how "push it" → "say yes" → "yes"
        // stays one fluid exchange.
        if let confirmation = model.assistantConfirmations.first,
           let decision = Self.confirmationDecision(from: spoken) {
            phase = .idle
            model.resolveAssistantConfirmation(confirmation.id, decision: decision)
            if let chatID = model.assistantChatID {
                let ack = if case .allow = decision { "Okay, going ahead." }
                    else { "Okay, I won't." }
                model.narration.speakAssistant(ack, chatID: chatID)
            }
            return
        }

        guard let assistant = model.assistantWorkspace else {
            phase = .idle
            return
        }
        awaitingSpokenReply = true
        phase = .thinking
        model.send(spoken, to: assistant.id)
        if let chatID = model.assistantChatID {
            // Instant feedback that the words landed; the real answer follows.
            model.narration.speakAssistant("On it.", chatID: chatID)
        }
        scheduleStillWorkingNudge()
    }

    /// One nudge, once, and only if the turn is genuinely still open — silence
    /// after "On it." is what makes a slow answer feel like a dropped one.
    private func scheduleStillWorkingNudge() {
        stillWorkingTask?.cancel()
        stillWorkingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stillWorkingDelay)
            guard !Task.isCancelled, let self, self.phase == .thinking,
                  let model = self.model, let chatID = model.assistantChatID
            else { return }
            model.narration.speakAssistant("Still on it — a moment.", chatID: chatID)
        }
    }

    // MARK: - Assistant events

    /// Assistant-chat agent events, forwarded from the model's intake.
    func observe(_ event: AgentEvent) {
        guard let model, let chatID = model.assistantChatID else { return }
        switch event {
        case .toolCall(let call):
            // Mid-turn milestones, only for turns the user is waiting on by
            // ear. Progress priority: they thin out under load, never delay
            // the reply, and are dropped wholesale the moment a mic opens.
            guard awaitingSpokenReply,
                  let phrase = Self.milestone(for: call.name),
                  phrase != lastMilestone || Date().timeIntervalSince(lastMilestoneAt) > 20,
                  Date().timeIntervalSince(lastMilestoneAt) >= Self.milestoneGap
            else { return }
            lastMilestone = phrase
            lastMilestoneAt = Date()
            model.narration.speakAssistant(phrase, chatID: chatID, priority: .progress)

        case .turnCompleted(let result):
            guard awaitingSpokenReply else { return }
            awaitingSpokenReply = false
            stillWorkingTask?.cancel()
            if phase == .thinking { phase = .idle }
            let line = NarrationPhraser.spokenNarration(result.narration)
                ?? "Done — the details are in the assistant window."
            model.narration.speakAssistant(line, chatID: chatID)

        case .sessionError(let error):
            guard awaitingSpokenReply else { return }
            awaitingSpokenReply = false
            stillWorkingTask?.cancel()
            if phase == .thinking { phase = .idle }
            model.narration.speakAssistant(
                "Something went wrong: \(error.message)", chatID: chatID
            )

        default:
            break
        }
    }

    /// A confirmation arrived. Inside a voice exchange it is narrated — and
    /// then the microphone opens by itself for a beat, so "yes" is just said,
    /// not chorded. Outside one, the notification and the Assistant window
    /// carry it.
    func confirmationArrived(_ confirmation: AssistantConfirmation) {
        guard let model, let chatID = model.assistantChatID else { return }
        let recentVoice = lastVoiceInteraction.map {
            Date().timeIntervalSince($0) < Self.voiceSessionWindow
        } ?? false
        guard awaitingSpokenReply || recentVoice else { return }
        model.narration.speakAssistant(
            "Quick check — \(confirmation.summary). Yes to allow it for this "
                + "task, or no.",
            chatID: chatID
        )
        // Only once the question has actually finished playing: opening the
        // mic ducks narration, which would cut the question off mid-word.
        model.narration.notifyWhenQuiet { [weak self] in
            self?.openAnswerWindow(for: confirmation.id)
        }
    }

    // MARK: - Hands-free answers

    private func openAnswerWindow(for confirmationID: String) {
        guard let model, phase == .idle, !voice.isActive,
              model.assistantConfirmations.contains(where: { $0.id == confirmationID })
        else { return }
        voice.vocabulary = []
        phase = .answering
        model.narration.setMicActive(true)
        voice.start()

        answerWindowTask?.cancel()
        answerWindowTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.answerWindow)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .answering, let model = self.model else { return }
                // Resolved from the window or the notification while we were
                // listening — nothing left to answer.
                guard model.assistantConfirmations.contains(where: { $0.id == confirmationID })
                else {
                    self.closeAnswerWindow()
                    return
                }
                guard Self.confirmationDecision(from: self.voice.transcript) != nil else {
                    continue
                }
                // A polarity appeared — but "no…" may still be becoming
                // "no problem, go ahead". Wait for the phrase to finish, then
                // read the whole utterance.
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, self.phase == .answering else { return }
                let settled = Self.confirmationDecision(from: self.voice.transcript)
                self.closeAnswerWindow()
                guard let settled else { return }
                self.lastVoiceInteraction = Date()
                model.resolveAssistantConfirmation(confirmationID, decision: settled)
                if let chatID = model.assistantChatID {
                    let ack = if case .allow = settled { "Okay, going ahead." }
                        else { "Okay, I won't." }
                    model.narration.speakAssistant(ack, chatID: chatID)
                }
                return
            }
            self?.closeAnswerWindow()
        }
    }

    private func closeAnswerWindow() {
        answerWindowTask?.cancel()
        answerWindowTask = nil
        guard phase == .answering else { return }
        if voice.isActive { voice.stop() }
        model?.narration.setMicActive(false)
        phase = .idle
    }

    // MARK: - Parsing

    /// What a tool call sounds like, for mid-turn narration. Only the ORE
    /// tools that represent real progress get a phrase; file reads and greps
    /// are mechanics, not milestones.
    nonisolated static func milestone(for tool: String) -> String? {
        let name = tool.components(separatedBy: "__").last ?? tool
        return switch name {
        case "ListWorkspaces": "Checking your workspaces."
        case "ListChats": "Looking through its chats."
        case "WorkspaceStatus": "Getting its status."
        case "SearchTranscripts": "Searching your history."
        case "GetTranscriptTail": "Reading the conversation."
        case "CreateWorkspace": "Spinning up a workspace."
        case "CreateChat": "Opening a chat."
        case "SendPromptToProject": "Handing it to the project's agent."
        case "Commit": "Committing."
        case "Push": "Pushing."
        case "CreatePullRequest": "Opening the pull request."
        case "ArchiveWorkspace": "Archiving."
        default: nil
        }
    }

    /// A spoken answer to a pending confirmation. The utterance is interpreted
    /// as a whole (see `ConfirmationIntent`); this is not a keyword scan.
    nonisolated static func confirmationDecision(
        from transcript: String
    ) -> AssistantConfirmationDecision? {
        ConfirmationIntent.decision(from: transcript)
    }
}
