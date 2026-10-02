import CoreGraphics
import Testing

@testable import OreMac

struct ComposerToolbarDensityTests {
    @Test func aWideColumnKeepsEveryLabelAndCapsTheModelToLeftover() {
        let density = ComposerToolbarDensity.resolve(
            availableWidth: 700,
            showsEffort: true,
            showsFast: true,
            showsMeter: true
        )
        #expect(density.kind == .roomy)
        #expect(density.showsEffortLabel)
        #expect(density.showsPermissionLabel)
        #expect(density.showsModeLabel)
        #expect(density.showsContextMeter)
        #expect(!density.compactsContextMeter)
        #expect(density.modelMaxWidth >= 88)
        #expect(density.modelMaxWidth <= 700)
    }

    @Test func aMidColumnDropsOrCompactsTheMeterBeforeLabels() {
        let density = ComposerToolbarDensity.resolve(
            availableWidth: 540,
            showsEffort: true,
            showsFast: true,
            showsMeter: true
        )
        #expect(density.kind == .regular)
        #expect(density.showsPermissionLabel)
        #expect(density.showsEffortLabel)
        #expect(density.modelMaxWidth >= 88)
    }

    @Test func aNarrowColumnHidesSecondaryLabels() {
        let density = ComposerToolbarDensity.resolve(
            availableWidth: 380,
            showsEffort: true,
            showsFast: true,
            showsMeter: true
        )
        #expect(density.kind == .compact || density.kind == .tight)
        #expect(!density.showsContextMeter)
        #expect(!density.showsPermissionLabel)
        #expect(!density.showsModeLabel)
        #expect(density.modelMaxWidth >= 64)
    }

    @Test func aTightColumnCollapsesEffortToAnIcon() {
        let density = ComposerToolbarDensity.resolve(
            availableWidth: 280,
            showsEffort: true,
            showsFast: true,
            showsMeter: true
        )
        #expect(density.kind == .tight)
        #expect(!density.showsEffortLabel)
        #expect(density.modelMaxWidth >= 64)
    }

    @Test func aLongModelNameStillLeavesRoomForSend() {
        // Mirrors the clipped screenshot: effort + Bypass, no Fast, no meter.
        let width: CGFloat = 480
        let density = ComposerToolbarDensity.resolve(
            availableWidth: width,
            showsEffort: true,
            showsFast: false,
            showsMeter: false
        )
        let reserved = ComposerToolbarDensity.reservedWidth(
            showsEffort: true,
            showsFast: false,
            showsMeter: density.showsContextMeter,
            compactMeter: density.compactsContextMeter,
            permissionLabel: density.showsPermissionLabel,
            modeLabel: density.showsModeLabel,
            effortLabel: density.showsEffortLabel
        )
        #expect(reserved + density.modelMaxWidth <= width + 0.5)
        #expect(density.modelMaxWidth >= 88)
    }

    @Test func missingOptionalChipsKeepASimplerRowRoomier() {
        let crowded = ComposerToolbarDensity.resolve(
            availableWidth: 500,
            showsEffort: true,
            showsFast: true,
            showsMeter: true
        )
        let simple = ComposerToolbarDensity.resolve(
            availableWidth: 500,
            showsEffort: false,
            showsFast: false,
            showsMeter: false
        )
        #expect(simple.kind == .roomy)
        #expect(simple.showsPermissionLabel)
        #expect(crowded.kind != .roomy || crowded.compactsContextMeter || !crowded.showsContextMeter)
    }
}
