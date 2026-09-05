import Testing
@testable import OreMac

/// The Liquid Glass surface system is mostly view rendering, which unit tests
/// can't see. What they *can* pin down is the depth grammar — the numbers that
/// decide whether a floating HUD panel reads as sitting above a menu, and a menu
/// above an in-app card. If those ever collapse into each other the glass stops
/// implying a hierarchy, so the ordering is worth guarding.
struct OreGlassTests {
    @Test func elevationShadowsClimbWithHeight() {
        // Higher surfaces cast softer, larger, more offset shadows: inset card <
        // anchored popover < detached floating panel.
        #expect(OreGlassElevation.inset.shadowRadius < OreGlassElevation.popover.shadowRadius)
        #expect(OreGlassElevation.popover.shadowRadius < OreGlassElevation.floating.shadowRadius)

        #expect(OreGlassElevation.inset.shadowY < OreGlassElevation.popover.shadowY)
        #expect(OreGlassElevation.popover.shadowY < OreGlassElevation.floating.shadowY)

        #expect(OreGlassElevation.inset.shadowOpacity < OreGlassElevation.popover.shadowOpacity)
        #expect(OreGlassElevation.popover.shadowOpacity < OreGlassElevation.floating.shadowOpacity)
    }

    @Test func everyElevationCastsAVisibleShadow() {
        // A zero shadow would flatten the surface onto its backdrop and defeat
        // the point of a floating material.
        for elevation in [OreGlassElevation.inset, .popover, .floating] {
            #expect(elevation.shadowRadius > 0)
            #expect(elevation.shadowOpacity > 0)
        }
    }

    @Test func glassShapeCarriesItsCornerRadius() {
        // The rect case must preserve the radius it was built with, since the
        // specular rim and the glass cutout both read from it.
        #expect(OreGlassShape.rect(cornerRadius: 12) == .rect(cornerRadius: 12))
        #expect(OreGlassShape.rect(cornerRadius: 12) != .rect(cornerRadius: 16))
        #expect(OreGlassShape.capsule != .rect(cornerRadius: 16))
    }
}
