import OreProtocol
import SwiftUI

/// The workspace review action lives beside commit and pull-request actions.
struct WorkspaceReviewButton: View {
    @Environment(AppModel.self) private var model
    let workspace: WorkspaceSummary
    @State private var reviewSetup: ReviewSetup?
    @State private var reviewInstructions = ""
    @State private var reviewModel = ""

    private struct ReviewSetup: Identifiable {
        var id: String { "review-setup" }
    }

    var body: some View {
        Button { startAIReview() } label: {
            HStack(spacing: 5) {
                if model.chatCreationsInFlight.contains(workspace.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                }
                Text("Review")
                if !draftComments.isEmpty {
                    Text("\(draftComments.count)")
                        .font(.caption2.monospacedDigit())
                }
            }
            .font(.system(size: OreTheme.Font.body, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(OreTheme.subduedFill, in: Capsule())
            .overlay(Capsule().stroke(OreTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(OrePressableButtonStyle())
        .disabled(model.chatCreationsInFlight.contains(workspace.id))
        .fixedSize(horizontal: true, vertical: false)
        .help("Open a dedicated agent review of the current diff")
        .contextMenu {
            ForEach(reviewModelChoices) { choice in
                Button(choice.displayName) { startAIReview(reviewerModel: choice.id) }
            }
            Divider()
            Button("Custom instructions…") {
                reviewModel = ""
                reviewSetup = ReviewSetup()
            }
        }
        .sheet(item: $reviewSetup) { _ in reviewSetupSheet }
    }

    private var draftComments: [DiffCommentReference] {
        if let inbox = model.reviewInboxChatID(for: workspace.id) {
            return model.chat(for: inbox).draftComments
        }
        return []
    }

    private func startAIReview(reviewerModel: String? = nil, instructions: String? = nil) {
        var prompt = """
        Review the current workspace diff. Look for correctness, security, tests, and maintainability. \
        Use GetWorkspaceDiff and GetDiffComments, then post each finding with PostDiffComment \
        (filePath, startLine, endLine, body) so they land as numbered anchored comments — not as prose. \
        After posting, list the findings as "1. … 2. …" so the user can say "fix 2 and 4".
        """
        if let instructions, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nAdditional instructions:\n\(instructions)"
        }
        model.createChat(
            in: workspace.id,
            initialMessage: prompt,
            defaults: reviewDefaults,
            model: reviewerModel,
            isReview: true
        )
    }

    /// The agent and model the Review button opens with, from Settings.
    private var reviewDefaults: AppModel.ChatDefaults {
        model.reviewDefaults(for: workspace.id)
    }

    /// Models to offer for a one-off review, drawn from the agent the review
    /// will actually run on rather than the workspace's.
    private var reviewModelChoices: [AgentModel] {
        model.knownModels(for: reviewDefaults.harness ?? workspace.harness)
    }

    private var reviewSetupSheet: some View {
        VStack(alignment: .leading, spacing: OreTheme.Space.md) {
            Text("Review with agent")
                .font(.system(size: 20, weight: .semibold))
            Picker("Model", selection: $reviewModel) {
                Text("Review default").tag("")
                ForEach(reviewModelChoices) { choice in
                    Text(choice.displayName).tag(choice.id)
                }
            }
            Text("Custom instructions")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $reviewInstructions)
                .font(.body)
                .frame(height: 120)
            HStack {
                Spacer()
                Button("Cancel") { reviewSetup = nil }
                    .buttonStyle(OreSecondaryButtonStyle())
                Button("Start review") {
                    startAIReview(
                        reviewerModel: reviewModel.isEmpty ? nil : reviewModel,
                        instructions: reviewInstructions
                    )
                    reviewSetup = nil
                }
                .buttonStyle(OrePrimaryButtonStyle())
            }
        }
        .padding(OreTheme.Space.lg)
        .frame(width: 480)
    }

}
