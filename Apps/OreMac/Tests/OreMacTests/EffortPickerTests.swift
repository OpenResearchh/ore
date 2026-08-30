import OreProtocol
import Testing

@testable import OreMac

struct EffortPickerTests {
    @Test func adaptiveOnlyModelDoesNotCreateDegenerateSlider() {
        let scale = EffortPickerScale(efforts: [.adaptive])

        #expect(scale.sliderRange == nil)
        #expect(scale.value(for: .high) == 0)
        #expect(scale.selection(at: 0) == .adaptive)
    }

    @Test func emptyCapabilitiesHaveNoSliderOrSelection() {
        let scale = EffortPickerScale(efforts: [])

        #expect(scale.sliderRange == nil)
        #expect(scale.selection(at: 0) == nil)
    }

    @Test func adjustableEffortsClampOutOfRangeInput() {
        let scale = EffortPickerScale(efforts: [.low, .medium, .high])

        #expect(scale.sliderRange == 0...2)
        #expect(scale.value(for: .medium) == 1)
        #expect(scale.selection(at: -10) == .low)
        #expect(scale.selection(at: 10) == .high)
    }
}
