import Foundation
import Testing

@testable import OreProtocol

struct PlanProposalPolicyTests {
    @Test func nameAndOverviewAloneAreNotReadyInput() {
        let input = JSONValue.object([
            "name": .string("Fix freeze"),
            "overview": .string("Main-thread saturation."),
        ])
        #expect(PlanProposalPolicy.planBody(from: input) == nil)
        #expect(!PlanProposalPolicy.hasTodos(in: input))
        #expect(!PlanProposalPolicy.isReadyInput(input))
    }

    @Test func aPlanBodyMakesTheInputReady() {
        let input = JSONValue.object([
            "name": .string("Fix freeze"),
            "plan": .string("Cause: the update loop.\nFix: profile, then batch."),
        ])
        #expect(PlanProposalPolicy.isReadyInput(input))
        #expect(PlanProposalPolicy.planBody(from: input)?.contains("update loop") == true)
    }

    @Test func streamContentCountsAsABodyWhileThePlanIsStillWriting() {
        let input = JSONValue.object([
            "name": .string("Fix freeze"),
            "streamContent": .string("Cause: the update loop.\n"),
        ])
        #expect(PlanProposalPolicy.isReadyInput(input))
        #expect(PlanProposalPolicy.planBody(from: input)?.contains("update loop") == true)
    }

    @Test func todosWithoutABodyAreReadyInput() {
        let input = JSONValue.object([
            "name": .string("Ship"),
            "todos": .array([.object(["content": .string("Write the test")])]),
        ])
        #expect(PlanProposalPolicy.isReadyInput(input))
        #expect(PlanProposalPolicy.hasTodos(in: input))
    }

    @Test func emptyMarkdownIsNotReady() {
        #expect(!PlanProposalPolicy.isReadyMarkdown(""))
        #expect(!PlanProposalPolicy.isReadyMarkdown("   \n  "))
        #expect(PlanProposalPolicy.isReadyMarkdown("## Steps\n1. Do it"))
    }

    @Test func mutatingToolsProceedPastAProposal() {
        #expect(PlanProposalPolicy.proceedsPastProposal("Edit"))
        #expect(PlanProposalPolicy.proceedsPastProposal("Write"))
        #expect(!PlanProposalPolicy.proceedsPastProposal("Read"))
        #expect(!PlanProposalPolicy.proceedsPastProposal("CreatePlan"))
    }

    @Test func jsonDebrisIsNotAPlanBody() {
        #expect(PlanProposalPolicy.normalizedMarkdown("}}") == nil)
        #expect(PlanProposalPolicy.normalizedMarkdown("},") == nil)
        #expect(!PlanProposalPolicy.isReadyMarkdown("}}"))
        #expect(PlanProposalPolicy.planBody(from: .object([
            "content": .string("}}\n"),
        ])) == nil)
    }

    @Test func aJSONEnvelopeUnwrapsToTheInnerPlan() {
        let envelope = """
        {"name":"Fix freeze","plan":"# Cause\\nThe update loop.\\n\\n# Fix\\nProfile, then batch."}
        """
        let body = PlanProposalPolicy.normalizedMarkdown(envelope)
        #expect(body?.contains("update loop") == true)
        #expect(body?.hasPrefix("#") == true)
        #expect(body?.contains("{") != true)
        #expect(PlanProposalPolicy.planBody(from: .object([
            "content": .string(envelope),
        ]))?.contains("Profile") == true)
    }

    @Test func leftoverBracesBeforeAnEnvelopeAreStripped() {
        let raw = """
        }}{"plan":"## Steps\\n1. Do the thing"}
        """
        let body = PlanProposalPolicy.normalizedMarkdown(raw)
        #expect(body?.contains("Do the thing") == true)
        #expect(body?.contains("}") != true)
    }

    @Test func aNestedResultEnvelopeUnwraps() {
        let raw = """
        {"result":{"success":{"plan":"Cause: the update loop.\\nFix: profile."}}}
        """
        #expect(PlanProposalPolicy.normalizedMarkdown(raw)?.contains("profile") == true)
    }

    @Test func aReadToolFileBodyIsNotAPlan() {
        let source = """
        guard let boldRange = result.string.range(of: "bold") else { return }
            let location = result.string.distance(
                from: result.string.startIndex, to: boldRange.lowerBound
            )
        """
        #expect(PlanProposalPolicy.planBody(from: .object([
            "content": .string(source),
        ])) == nil)
        #expect(!PlanProposalPolicy.isReadyInput(.object([
            "path": .string("/tmp/RenderingTests.swift"),
            "content": .string(source),
        ])))
    }

    @Test func jsonWithoutAPlanFieldIsNotMarkdown() {
        let dump = """
        {"mode":"search","pattern":"plan","matches":[]}
        """
        #expect(PlanProposalPolicy.normalizedMarkdown(dump) == nil)
        #expect(PlanProposalPolicy.planBody(from: .object([
            "content": .string(dump),
        ])) == nil)
    }

    @Test func incompleteJSONStreamChunksAreNotABody() {
        #expect(PlanProposalPolicy.normalizedMarkdown(#"{"name": "Fix freeze""#) == nil)
        #expect(PlanProposalPolicy.planBody(from: .object([
            "streamContent": .string("}}"),
        ])) == nil)
        #expect(!PlanProposalPolicy.isReadyInput(.object([
            "name": .string("Fix freeze"),
            "streamContent": .string("}}"),
        ])))
    }

    @Test func createPlanArgsWithoutAPlanFieldAreNotABody() {
        let args = """
        {"name":"Fix freeze","overview":"Main-thread saturation."}
        """
        #expect(PlanProposalPolicy.normalizedMarkdown(args) == nil)
        #expect(PlanProposalPolicy.planBody(from: .object([
            "streamContent": .string(args),
        ])) == nil)
    }
}

struct PlanReadinessGateTests {
    @Test func aDraftDoesNotAnnounce() {
        var gate = PlanReadinessGate()
        let announced = gate.shouldAnnounce(
            scope: "c1", turnID: TurnID(rawValue: "t1"),
            markdown: "Steps\n1. Do it", isReady: false
        )
        #expect(!announced)
    }

    @Test func emptyReadyMarkdownDoesNotAnnounce() {
        var gate = PlanReadinessGate()
        let announced = gate.shouldAnnounce(
            scope: "c1", turnID: TurnID(rawValue: "t1"),
            markdown: "  ", isReady: true
        )
        #expect(!announced)
    }

    @Test func theFirstReadyProposalAnnouncesAndDuplicatesDoNot() {
        var gate = PlanReadinessGate()
        let turn = TurnID(rawValue: "t1")
        let first = gate.shouldAnnounce(
            scope: "c1", turnID: turn, markdown: "Steps\n1. Do it", isReady: true
        )
        let duplicate = gate.shouldAnnounce(
            scope: "c1", turnID: turn, markdown: "Steps\n1. Do it", isReady: true
        )
        let grown = gate.shouldAnnounce(
            scope: "c1", turnID: turn,
            markdown: "Steps\n1. Do it\n2. More", isReady: true
        )
        #expect(first)
        #expect(!duplicate)
        #expect(!grown, "a later body on the same turn must not re-advertise")
    }

    @Test func aNewTurnCanAnnounceAgain() {
        var gate = PlanReadinessGate()
        let first = gate.shouldAnnounce(
            scope: "c1", turnID: TurnID(rawValue: "t1"),
            markdown: "first", isReady: true
        )
        gate.reset(scope: "c1")
        let second = gate.shouldAnnounce(
            scope: "c1", turnID: TurnID(rawValue: "t2"),
            markdown: "second", isReady: true
        )
        #expect(first)
        #expect(second)
    }
}
