import OreProtocol
import Testing

@testable import OreMac

struct PlanDecisionFeedbackTests {
    @Test func preservesTypedFeedbackWithoutComments() {
        #expect(
            PlanDecisionFeedback.combining("  Keep the API small.  ", comments: [])
                == "Keep the API small."
        )
    }

    @Test func includesCommentLocationsBodiesAndContext() {
        let comments = [
            DiffCommentReference(
                filePath: "Sources/Feature.swift",
                startLine: 12,
                endLine: 14,
                body: "Keep this work off the main actor.",
                context: "func load() async {}"
            ),
            DiffCommentReference(
                filePath: "Tests/FeatureTests.swift",
                startLine: 38,
                endLine: 38,
                body: "Cover the failure path."
            ),
        ]

        let result = PlanDecisionFeedback.combining(
            "Please revise before implementing.", comments: comments
        )

        #expect(result.contains("Please revise before implementing."))
        #expect(result.contains("Sources/Feature.swift:12-14"))
        #expect(result.contains("Keep this work off the main actor."))
        #expect(result.contains("func load() async {}"))
        #expect(result.contains("Tests/FeatureTests.swift:38"))
        #expect(result.contains("Cover the failure path."))
    }

    @Test func commentsStillTravelWithoutTypedFeedback() {
        let result = PlanDecisionFeedback.combining(
            "",
            comments: [
                DiffCommentReference(
                    filePath: "Sources/Feature.swift",
                    startLine: 9,
                    endLine: 9,
                    body: "Keep this lazy."
                ),
            ]
        )

        #expect(result.hasPrefix("Review comments on the current diff:"))
        #expect(result.contains("Sources/Feature.swift:9"))
        #expect(result.contains("Keep this lazy."))
    }
}
