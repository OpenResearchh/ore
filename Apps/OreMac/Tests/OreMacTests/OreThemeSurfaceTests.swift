import AppKit
import Testing
@testable import OreMac

/// Pins the dark canvas against system gray. Full screen used to be three
/// slightly different `textBackgroundColor` boxes; these numbers are what
/// keeps the reading surface near-black and the sidebar cooler than it.
struct OreThemeSurfaceTests {
    @Test func darkContentIsDarkerAndWarmerThanSystemGray() {
        let dark = NSAppearance(named: .darkAqua)!
        let content = srgb(OreTheme.Surface.contentColor, in: dark)
        let system = srgb(NSColor.textBackgroundColor, in: dark)
        #expect(luminance(content) < luminance(system))
        #expect(content.redComponent >= content.blueComponent)
    }

    @Test func darkChromeIsCoolerThanTheReadingSurface() {
        let dark = NSAppearance(named: .darkAqua)!
        let content = srgb(OreTheme.Surface.contentColor, in: dark)
        let chrome = srgb(OreTheme.Surface.chromeColor, in: dark)
        #expect(chrome.blueComponent > chrome.redComponent)
        #expect(content.redComponent > chrome.redComponent
            || content.blueComponent < chrome.blueComponent)
    }

    @Test func lightModeKeepsSystemSurfaces() {
        let light = NSAppearance(named: .aqua)!
        let content = srgb(OreTheme.Surface.contentColor, in: light)
        let system = srgb(NSColor.textBackgroundColor, in: light)
        #expect(abs(content.redComponent - system.redComponent) < 0.02)
        #expect(abs(content.greenComponent - system.greenComponent) < 0.02)
        #expect(abs(content.blueComponent - system.blueComponent) < 0.02)
    }

    private func srgb(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            color.usingColorSpace(.sRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}
