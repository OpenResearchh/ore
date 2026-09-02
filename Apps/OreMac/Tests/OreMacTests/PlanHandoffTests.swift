import Testing

@testable import OreMac

struct PlanHandoffTests {
    @Test func trimsAndAppendsATrailingNewline() {
        let draft = PlanHandoff.composerDraft(from: "  ## Steps\n1. Do the thing  \n")
        #expect(draft == "## Steps\n1. Do the thing\n")
    }

    @Test func emptyMarkdownIsNothingToHandOff() {
        #expect(PlanHandoff.composerDraft(from: "") == nil)
        #expect(PlanHandoff.composerDraft(from: " \n\t ") == nil)
    }

    @Test func alreadyTrimmedMarkdownStillGetsATrailingNewline() {
        #expect(PlanHandoff.composerDraft(from: "Ship it") == "Ship it\n")
    }

    @Test func aJSONEnvelopeHandsOffTheInnerPlan() {
        let envelope = """
        {"name":"Fix freeze","plan":"## Steps\\n1. Do the thing"}
        """
        #expect(PlanHandoff.composerDraft(from: envelope) == "## Steps\n1. Do the thing\n")
    }

    @Test func jsonDebrisIsNothingToHandOff() {
        #expect(PlanHandoff.composerDraft(from: "}}") == nil)
    }
}
