import OreProtocol
import SwiftUI

/// Creating a workspace by saying what you want.
///
/// The form this stands in front of asked nine questions — repository source,
/// repository, identity, agent, model, starting branch, first message, create
/// another. Almost every one has an answer the machine can work out, and the
/// few that don't can be said in passing: "take ore, use Claude Code, and
/// branch from release". So the default is one sentence and a Start button,
/// and the nine controls move behind "Advanced", where they remain overrides
/// rather than setup.
///
/// The guess is always on screen and always one click from being changed. That
/// is the difference between inference the user trusts and inference that
/// surprises them: nothing is hidden, it just isn't asked.
struct NewWorkspaceComposer: View {
    @Environment(AppModel.self) private var model

    @Binding var instruction: String
    /// Non-nil once the user overrules the inferred project.
    @Binding var repositoryOverride: String?
    @Binding var harnessOverride: HarnessKind?
    @Binding var modelOverride: String?
    /// The user asked for a fresh project rather than any existing one.
    @Binding var wantsNewProject: Bool
    let isCreating: Bool
    var onStart: () -> Void
    var onAdvanced: () -> Void
    /// Opens the GitHub picker, which lives in Advanced because it needs auth,
    /// search and a clone — none of which belong on the fast path.
    var onBrowseGitHub: () -> Void

    @State private var voice = VoiceInputController()
    @FocusState private var writing: Bool

    /// The reading of what the user has said so far, against this machine's
    /// actual agents, models and projects. The same resolution the sheet
    /// submits, so the chips below cannot disagree with what gets started.
    private var plan: WorkspaceLaunchPlan {
        WorkspaceLaunchPlan.resolve(model.launchInputs(
            instruction: instruction,
            harnessOverride: harnessOverride,
            modelOverride: modelOverride,
            repositoryOverride: repositoryOverride,
            wantsNewProject: wantsNewProject
        ))
    }

    private var intent: WorkspaceIntent { plan.intent }
    private var choice: WorkspaceInference.Choice? { plan.repository }

    /// Start is for starting work.
    ///
    /// Having somewhere to work is deliberately *not* a condition: with no
    /// project ORE makes one, which is the whole point of not asking. Having
    /// the *right* somewhere is: an ambiguous project, or a name ORE cannot
    /// place, has to be settled before a worktree appears in a repository the
    /// user never mentioned.
    private var canStart: Bool {
        plan.canStart && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.md) {
            Text("What do you want ORE to work on?")
                .font(.system(size: 20, weight: .semibold))

            surface
            footer
        }
        .padding(OreTheme.Space.lg)
        .frame(width: 560)
        .animation(.easeOut(duration: 0.18), value: voice.isListening)
        .onDisappear { voice.stop() }
        // Dictation lands in the same field typing does, so the two are one
        // input rather than two modes.
        .onChange(of: voice.transcript) { _, spoken in
            guard voice.isActive, !spoken.isEmpty else { return }
            instruction = spoken
        }
    }

    // MARK: - The one input

    /// Text above, controls below, in a single surface — the same shape as the
    /// chat composer, because it is the same gesture.
    private var surface: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if instruction.isEmpty {
                    Text(voice.isListening ? "Listening…" : "Tell ORE what you want to work on…")
                        .font(.system(size: OreTheme.Font.title))
                        .foregroundStyle(.secondary)
                        // Matched to the editor's own text inset so the two
                        // strings sit on exactly one baseline.
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $instruction)
                    .font(.system(size: OreTheme.Font.title))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .padding(.vertical, 8)
                    .focused($writing)
                    .frame(height: 72)
            }
            .padding(.horizontal, 10)

            controlBar
        }
        // The app's own glass, not a flat fill: this is the one high-value
        // surface on the panel, which is exactly what `OreGlassSurface` is
        // for. It tints toward the accent while dictating, so the surface
        // itself carries the listening state rather than a separate indicator.
        .modifier(OreGlassSurface(
            shape: .rect(cornerRadius: OreTheme.cardRadius),
            tint: voice.isListening ? Color.accentColor.opacity(0.10) : nil,
            elevation: .inset
        ))
        .overlay {
            RoundedRectangle(cornerRadius: OreTheme.cardRadius, style: .continuous)
                .stroke(
                    voice.isListening ? Color.accentColor.opacity(0.55) : Color.clear,
                    lineWidth: 1.5
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { writing = true }
    }

    private var controlBar: some View {
        HStack(spacing: OreTheme.Space.sm) {
            micButton
            if voice.isActive {
                WaveformBars(mode: .listening, level: { voice.audioLevel })
                    .frame(width: 30, height: 16)
                    .transition(.opacity)
            }
            HStack(spacing: 5) {
                HarnessMark(harness: effectiveHarness, size: 14)
                modelPicker
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(OreTheme.glassControlFill, in: Capsule())
            readings
            Spacer(minLength: OreTheme.Space.sm)
            Button(action: onStart) {
                HStack(spacing: 5) {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(isCreating ? "Starting…" : "Start")
                }
            }
            .buttonStyle(OrePrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canStart)
            .help(canStart
                ? "Start work (⌘↩)"
                : plan.blockerMessage ?? "Say what you want ORE to work on")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    /// Agent and model in one control.
    ///
    /// Not a labelled row of two pickers — that is the form this replaces. It
    /// shows the mark of whatever will actually run, so the default is legible
    /// at a glance and changing it is one click, without model choice becoming
    /// a question the user has to answer before starting.
    private var modelPicker: some View {
        Menu {
            ForEach(model.readyHarnesses, id: \.self) { kind in
                Section(kind.displayName) {
                    Button("Default model") { select(kind, model: nil) }
                    ForEach(model.knownModels(for: kind)) { choice in
                        Button(choice.displayName) { select(kind, model: choice.id) }
                    }
                }
            }
        } label: {
            Text(effectiveModelLabel)
                .lineLimit(1)
                .font(.system(size: OreTheme.Font.caption))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The mark sits *beside* the menu, not inside its label. A `Menu`
        // label does not honour a fixed frame on a `.resizable()` image — it
        // took the image's natural size instead, and drew the Claude logo at
        // about 130pt across the middle of the composer.
        .padding(.leading, 2)
        .background(alignment: .leading) { Color.clear }
        .help("The agent and model this workspace starts with")
    }

    private var effectiveHarness: HarnessKind { plan.harness }

    private var effectiveModelLabel: String {
        guard let chosen = plan.model ?? plan.unavailableModel else { return "Default" }
        return model.knownModels(for: plan.harness)
            .first { $0.id == chosen }?.displayName ?? chosen
    }

    private func select(_ kind: HarnessKind, model id: String?) {
        harnessOverride = kind
        modelOverride = id
    }

    /// Speaking is a first-class way in, so the mic is a real target rather
    /// than a glyph — but it lives in the control bar with everything else,
    /// because a button floating in the text is a button in the way.
    private var micButton: some View {
        Button { voice.toggle() } label: {
            Image(systemName: voice.isListening ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(voice.isListening ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
                .background(
                    voice.isListening
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(OreTheme.glassControlFill),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(voice.isListening ? "Stop listening" : "Speak your instruction")
    }

    // MARK: - What ORE worked out

    /// One quiet line: where the work will happen, and the way out to the
    /// controls. Both trailing-aligned against the project so the row reads
    /// left-to-right as statement then correction.
    private var footer: some View {
        HStack(spacing: OreTheme.Space.sm) {
            if let choice {
                Image(systemName: choice.isSettled ? "folder" : "questionmark.circle")
                    .foregroundStyle(choice.isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                // A project ORE is unsure about is not announced as the
                // answer. Naming it here read as "this is where it's going",
                // which is the impression the whole blocker exists to avoid.
                if choice.isSettled {
                    Text(WorkspaceInference.name(of: choice.path))
                        .fontWeight(.medium)
                }
                Text(plan.blockerMessage ?? choice.reason)
                    .foregroundStyle(choice.isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // Not an error and not a blocker: with nothing to work in,
                // Start makes a project rather than sending the user away to
                // set one up first.
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text("ORE will start a new project")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: OreTheme.Space.sm)

            Menu {
                if !model.repositories.isEmpty {
                    Section("On this Mac") {
                        ForEach(model.repositories, id: \.self) { path in
                            Button(WorkspaceInference.name(of: path)) { repositoryOverride = path }
                        }
                    }
                }
                Section {
                    Button("Browse GitHub…", action: onBrowseGitHub)
                    Button("New project") { repositoryOverride = nil; wantsNewProject = true }
                }
            } label: {
                Text(model.repositories.isEmpty ? "Choose" : "Change")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)

            Button("Advanced", action: onAdvanced)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Agent, model, branch and identity — overrides, not setup")
        }
        .font(.system(size: OreTheme.Font.caption))
        .padding(.horizontal, 2)
    }

    /// Only what was actually heard. Empty means ORE is using its defaults,
    /// which is the normal case and needs no explaining.
    @ViewBuilder
    private var readings: some View {
        let intent = intent
        if intent.harness != nil || intent.model != nil || intent.baseBranch != nil {
            HStack(spacing: 4) {
                if let harness = intent.harness { chip(harness.displayName) }
                if let model = intent.model { chip(model) }
                if let branch = intent.baseBranch { chip("from \(branch)") }
            }
            .transition(.opacity)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: OreTheme.Font.caption))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(OreTheme.glassControlFill, in: Capsule())
            .lineLimit(1)
    }
}
