import SwiftUI

/// Turns raw calibration transcripts into a widened `FinishPhraseModel`.
///
/// The user says the finish phrase a few times through the *production*
/// recognition pipeline; whatever the recognizer actually wrote down becomes
/// candidate variants. Pure and synchronous — the microphone work lives in
/// `FinishPhraseTuner`.
enum FinishPhraseEnrollment {
    struct Derivation: Equatable {
        var variants: [[String]]
        var warnings: [Warning]
    }

    enum Warning: Equatable {
        /// A variant leans on everyday words; accepting it risks sending
        /// half-finished requests when those words occur as prose.
        case commonWords([String])
        case nothingHeard
        case tooShort([String])
        case identicalToCanonical
    }

    static let variantCap = 8

    /// Words far too common in ordinary speech to end a request on. A
    /// custom phrase or variant may still use them — but only past an
    /// explicit warning.
    static let stopList: Set<String> = [
        "a", "and", "are", "be", "but", "do", "for", "go", "i", "in", "is",
        "it", "know", "like", "me", "no", "not", "now", "of", "oh", "okay",
        "on", "one", "right", "so", "that", "the", "this", "to", "two",
        "uh", "um", "was", "we", "well", "what", "yeah", "yes", "you",
        // The confirmation vocabulary: a finish phrase colliding with
        // spoken yes/no answers would fight the answer mic.
        "allow", "always", "approve", "cancel", "deny", "never", "reject",
        "send", "stop", "sure",
    ]

    static func derive(
        from transcripts: [String],
        canonical: [String]
    ) -> Derivation {
        let n = canonical.count
        var seen = Set<[String]>()
        var variants: [[String]] = []
        var offendingWords = Set<String>()
        var sawCanonical = false
        var shortVariants: [[String]] = []

        for transcript in transcripts {
            let tokens = words(in: transcript)
            guard !tokens.isEmpty else { continue }
            let trailing = Array(tokens.suffix(n + 2))
            if trailing == canonical {
                sawCanonical = true
                continue
            }
            guard seen.insert(trailing).inserted else { continue }
            guard variants.count < variantCap else { continue }
            variants.append(trailing)
            offendingWords.formUnion(trailing.filter { stopList.contains($0) })
            if trailing.count == 1, trailing.joined().count < canonical.joined().count / 2 {
                shortVariants.append(trailing)
            }
        }

        var warnings: [Warning] = []
        if variants.isEmpty, transcripts.allSatisfy({ words(in: $0).isEmpty }) {
            warnings.append(.nothingHeard)
        }
        if sawCanonical { warnings.append(.identicalToCanonical) }
        if !shortVariants.isEmpty { warnings.append(.tooShort(shortVariants[0])) }
        if !offendingWords.isEmpty {
            warnings.append(.commonWords(offendingWords.sorted()))
        }
        return Derivation(
            variants: variants,
            warnings: warnings
        )
    }

    /// Validation for a user-chosen custom phrase.
    static func phraseWarnings(for phrase: String) -> [String] {
        let tokens = words(in: phrase)
        var warnings: [String] = []
        if tokens.count < 3 {
            warnings.append("Three or more words are much harder to trip by accident.")
        }
        if tokens.count > 6 {
            warnings.append("Use six words or fewer so the ending stays quick and recognizable.")
        }
        let common = tokens.filter { stopList.contains($0) }
        if !common.isEmpty {
            warnings.append(
                "“\(common.joined(separator: "”, “"))” shows up in ordinary speech — a request could send itself."
            )
        }
        return warnings
    }

    static func words(in text: String) -> [String] {
        FinishPhraseMatching.words(in: text)
    }
}

/// Runs the calibration takes: opens the same recognizer the hands-free
/// session uses, waits for the hypothesis to settle, and collects what was
/// actually transcribed. Its own `VoiceInputController` keeps state isolated;
/// explicit handoff below keeps it from contending with composer dictation.
@MainActor
@Observable
final class FinishPhraseTuner {
    enum Step: Equatable {
        case idle
        case recording
        case review
    }

    static let takeTarget = 3
    static let maximumTakes = 5
    /// A take ends when the transcript has held still this long.
    static let takeSettle = Duration.milliseconds(900)
    /// No take runs longer than this, spoken or silent.
    static let takeLimit = Duration.seconds(10)

    private(set) var step: Step = .idle
    private(set) var takes: [String] = []
    private(set) var derivation: FinishPhraseEnrollment.Derivation?
    private(set) var acceptedVariants: Set<Int> = []
    private(set) var model: FinishPhraseModel
    private(set) var phraseChanged = false

    let voice = VoiceInputController()
    private var settleTask: Task<Void, Never>?
    private weak var narration: NarrationEngine?

    init() {
        model = FinishPhraseStore.load() ?? .standard
    }

    var isTuned: Bool { FinishPhraseStore.load() != nil }
    var canSave: Bool {
        derivation != nil && (phraseChanged || !acceptedVariants.isEmpty)
    }
    var nextTakeLabel: String {
        let goal = takes.count < Self.takeTarget ? Self.takeTarget : Self.maximumTakes
        return "Record take \(takes.count + 1) of \(goal)"
    }

    func beginTake(narration: NarrationEngine) {
        guard !voice.isActive, step != .recording else { return }
        step = .recording
        self.narration = narration
        // A composer may still own the device even while the assistant itself
        // is idle. Ask it to park its draft, then take ownership after the same
        // release beat used by the assistant microphone.
        VoiceHotkeyMonitor.shared.requestComposerCommit()
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, self.step == .recording else { return }
            narration.setMicActive(true)
            self.voice.vocabulary = self.model.vocabulary
            self.voice.start()
            let startedAt = ContinuousClock.now
            var lastChangeAt = startedAt
            var lastTranscript = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                if case .error = self.voice.status {
                    self.endTake(keep: false)
                    return
                }
                let now = ContinuousClock.now
                let current = self.voice.transcript
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let currentKey = FinishPhraseEnrollment.words(in: current).joined(separator: " ")
                if currentKey != lastTranscript {
                    lastTranscript = currentKey
                    lastChangeAt = now
                }
                let settled = !current.isEmpty && now - lastChangeAt >= Self.takeSettle
                if settled || now - startedAt >= Self.takeLimit || !self.voice.isActive {
                    self.endTake(keep: true)
                    return
                }
            }
        }
    }

    func cancelTake() {
        endTake(keep: false)
    }

    func finishTake() {
        endTake(keep: true)
    }

    private func endTake(keep: Bool) {
        settleTask?.cancel()
        settleTask = nil
        let heard = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if voice.isActive { voice.stop() }
        narration?.setMicActive(false)
        narration = nil
        if keep, !heard.isEmpty { takes.append(heard) }
        if takes.count >= Self.takeTarget {
            deriveNow()
        } else {
            step = .idle
        }
    }

    func deriveNow() {
        let derived = FinishPhraseEnrollment.derive(
            from: takes, canonical: model.canonicalTokens
        )
        derivation = derived
        // Everything starts accepted except variants that lean on common
        // words — those the user has to opt into deliberately.
        var accepted = Set(derived.variants.indices)
        for (index, variant) in derived.variants.enumerated()
        where variant.contains(where: { FinishPhraseEnrollment.stopList.contains($0) })
            || (variant.count == 1
                && variant.joined().count < model.canonicalTokens.joined().count / 2) {
            accepted.remove(index)
        }
        acceptedVariants = accepted
        step = .review
    }

    func toggleVariant(_ index: Int) {
        if acceptedVariants.contains(index) {
            acceptedVariants.remove(index)
        } else {
            acceptedVariants.insert(index)
        }
    }

    func discardTakes() {
        settleTask?.cancel()
        settleTask = nil
        if voice.isActive { voice.stop() }
        narration?.setMicActive(false)
        narration = nil
        takes = []
        derivation = nil
        acceptedVariants = []
        step = .idle
    }

    func addAnotherTake() {
        guard step == .review, takes.count < Self.maximumTakes else { return }
        derivation = nil
        acceptedVariants = []
        step = .idle
    }

    /// Replace the phrase itself. Everything learned about the old phrase
    /// is meaningless for the new one, so takes and variants reset.
    func setCustomPhrase(_ phrase: String) {
        let tokens = FinishPhraseEnrollment.words(in: phrase)
        guard (3...6).contains(tokens.count) else { return }
        model = FinishPhraseModel(
            spoken: tokens.joined(separator: " "),
            canonicalTokens: tokens,
            slotAlternatives: tokens.map { [$0] },
            enrolledVariants: []
        )
        phraseChanged = true
        discardTakes()
    }

    func save() {
        guard let derivation else { return }
        var updated = model
        for (index, variant) in derivation.variants.enumerated()
        where acceptedVariants.contains(index) && !updated.enrolledVariants.contains(variant) {
            updated.enrolledVariants.append(variant)
        }
        guard let validated = updated.validated() else { return }
        model = validated
        FinishPhraseStore.save(validated)
        phraseChanged = false
        discardTakes()
    }

    func resetToStock() {
        FinishPhraseStore.clear()
        model = .standard
        phraseChanged = false
        discardTakes()
    }
}

/// The Settings sheet: pick the phrase, record a few takes through the real
/// recognizer, approve what it heard.
struct FinishPhraseTuningSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var tuner = FinishPhraseTuner()
    @State private var phraseDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tune the finish phrase")
                .font(.system(size: 16, weight: .semibold))
            Text("Say “\(tuner.model.spoken)” a few times the way you naturally would. Whatever the recognizer hears becomes an accepted way to end a request — so it works with your voice, your mic, and your accent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            phraseRow
            Divider()

            switch tuner.step {
            case .idle, .recording:
                recordingSection
            case .review:
                reviewSection
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 440, height: 430)
        .onAppear { phraseDraft = tuner.model.spoken }
        .onDisappear { tuner.discardTakes() }
    }

    private var phraseRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Finish phrase", text: $phraseDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Use phrase") {
                    tuner.setCustomPhrase(phraseDraft)
                    phraseDraft = tuner.model.spoken
                }
                .disabled(
                    FinishPhraseEnrollment.words(in: phraseDraft).count < 3
                        || FinishPhraseEnrollment.words(in: phraseDraft).count > 6
                        || phraseDraft == tuner.model.spoken
                )
            }
            ForEach(
                FinishPhraseEnrollment.phraseWarnings(for: phraseDraft),
                id: \.self
            ) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(tuner.takes.indices, id: \.self) { index in
                Label("“\(tuner.takes[index])”", systemImage: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if tuner.step == .recording {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(0.35 + 0.65 * tuner.voice.audioLevel)
                    Text(tuner.voice.transcript.isEmpty
                         ? "Listening — say the phrase…"
                         : tuner.voice.transcript)
                        .font(.system(size: 12))
                        .lineLimit(2)
                    Spacer()
                    Button("Use take") { tuner.finishTake() }
                    Button("Cancel") { tuner.cancelTake() }
                }
            } else {
                HStack {
                    Button {
                        tuner.beginTake(narration: appModel.narration)
                    } label: {
                        Label(
                            tuner.nextTakeLabel,
                            systemImage: "mic.fill"
                        )
                    }
                    if tuner.takes.count >= FinishPhraseTuner.takeTarget {
                        Button("Finish early") { tuner.deriveNow() }
                    }
                }
            }
            if case .error(let message) = tuner.voice.status {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let derivation = tuner.derivation {
                if derivation.variants.isEmpty {
                    Label(
                        "Every take came back as the phrase itself — recognition already hears you. Nothing to add.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("The recognizer heard these endings. Checked ones will also finish a request:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(derivation.variants.indices, id: \.self) { index in
                        Toggle(
                            "“\(derivation.variants[index].joined(separator: " "))”",
                            isOn: Binding(
                                get: { tuner.acceptedVariants.contains(index) },
                                set: { _ in tuner.toggleVariant(index) }
                            )
                        )
                        .font(.system(size: 12))
                    }
                    ForEach(derivation.warnings.indices, id: \.self) { index in
                        switch derivation.warnings[index] {
                        case .commonWords(let words):
                            Label(
                                "“\(words.joined(separator: "”, “"))” are everyday words — variants using them start unchecked because they can fire mid-sentence.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        case .tooShort:
                            Label(
                                "A very short result is risky and starts unchecked.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        case .identicalToCanonical, .nothingHeard:
                            EmptyView()
                        }
                    }
                }
            }
            HStack {
                Button("Record again") { tuner.discardTakes() }
                if tuner.takes.count < FinishPhraseTuner.maximumTakes {
                    Button("Add another take") { tuner.addAnotherTake() }
                }
                Button("Save") { tuner.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!tuner.canSave)
            }
        }
    }

    private var footer: some View {
        HStack {
            if tuner.isTuned {
                Button("Reset to “\(FinishPhraseModel.standard.spoken)”") {
                    tuner.resetToStock()
                    phraseDraft = tuner.model.spoken
                }
            }
            Spacer()
            Button("Done") { dismiss() }
        }
    }
}
