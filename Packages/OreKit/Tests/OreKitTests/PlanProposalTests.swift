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
