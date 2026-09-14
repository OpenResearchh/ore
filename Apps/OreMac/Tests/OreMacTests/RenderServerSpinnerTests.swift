import AppKit
import Testing

@testable import OreMac

@MainActor
struct RenderServerSpinnerTests {
    private func hosted<V: NSView>(_ view: V, size: NSSize) -> (NSWindow, V) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 800, height: 600)),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    @Test func attachingToAWindowHandsTheRotationToTheRenderServer() {
        let (window, view) = hosted(SweepingBorderView(), size: NSSize(width: 520, height: 96))
        defer { window.close() }
        view.period = 2.4

        let spin = view.spinner.animation(forKey: "ore.spin") as? CABasicAnimation
        #expect(spin?.keyPath == "transform.rotation.z")
        #expect(spin?.duration == 2.4)
        #expect(spin?.repeatCount == .infinity)
        #expect(view.stage.speed == 1)
    }

    @Test func theSpinnerIsASquareOnTheDiagonalSoCornersNeverRotateOutOfTheMask() {
        let (window, view) = hosted(SweepingBorderView(), size: NSSize(width: 300, height: 400))
        defer { window.close() }
        view.layout()

        #expect(view.spinner.bounds.size == CGSize(width: 500, height: 500))
        #expect(view.spinner.position == CGPoint(x: 150, y: 200))
    }

    @Test func resizingTheFrameLaysTheSpinnerOutAgain() {
        let (window, view) = hosted(SweepingBorderView(), size: NSSize(width: 300, height: 400))
        defer { window.close() }
        view.setFrameSize(NSSize(width: 600, height: 800))

        #expect(view.needsLayout)
        view.layoutSubtreeIfNeeded()
        #expect(view.spinner.bounds.size == CGSize(width: 1000, height: 1000))
    }

    @Test func pausingFreezesTheStageAndResumingCarriesOnFromThere() {
        let (window, view) = hosted(OrbitingArcView(), size: NSSize(width: 33, height: 33))
        defer { window.close() }

        view.isPaused = true
        #expect(view.stage.speed == 0)
        let frozenAt = view.stage.timeOffset
        #expect(frozenAt > 0)

        view.isPaused = false
        #expect(view.stage.speed == 1)
        #expect(view.stage.timeOffset == 0)
        // Local time picks up where it stood, not where the clock is now.
        let resumedAt = view.stage.convertTime(CACurrentMediaTime(), from: nil)
        #expect(abs(resumedAt - frozenAt) < 0.5)
        #expect(view.spinner.animation(forKey: "ore.spin") != nil)
    }

    @Test func aViewPausedBeforeItsWindowStaysPausedOnceAttached() {
        let view = OrbitingArcView()
        view.isPaused = true
        let (window, attached) = hosted(view, size: NSSize(width: 33, height: 33))
        defer { window.close() }

        #expect(attached.stage.speed == 0)
        #expect(attached.spinner.animation(forKey: "ore.spin") != nil)
    }

    @Test func handMadeLayersFollowTheWindowsBackingScale() {
        let (window, view) = hosted(SweepingBorderView(), size: NSSize(width: 200, height: 60))
        defer { window.close() }

        #expect(view.spinner.contentsScale == window.backingScaleFactor)
        #expect(view.layer?.mask?.contentsScale == window.backingScaleFactor)
    }

    @Test func theArcIsCentredOnTheInscribedCircleLikeATrimmedSwiftUICircle() throws {
        let (window, view) = hosted(OrbitingArcView(), size: NSSize(width: 40, height: 30))
        defer { window.close() }
        view.layout()

        let arc = try #require(view.spinner as? CAShapeLayer)
        let path = try #require(arc.path)
        let center = CGPoint(x: arc.bounds.midX, y: arc.bounds.midY)
        // The arc starts at angle zero, one radius to the right of centre.
        #expect(abs(path.boundingBoxOfPath.maxX - (center.x + 15)) < 0.01)
        #expect(arc.lineWidth == 2)
        #expect(arc.lineCap == .round)
    }

    @Test func decorationNeverTakesClicks() {
        let (window, view) = hosted(SweepingBorderView(), size: NSSize(width: 200, height: 60))
        defer { window.close() }

        #expect(view.hitTest(NSPoint(x: 100, y: 30)) == nil)
    }

    // MARK: - Pulsing dot

    @Test func busyDotsBreatheOnTheRenderServerInStep() throws {
        let (window, view) = hosted(PulsingDotView(frame: .zero), size: NSSize(width: 6, height: 6))
        defer { window.close() }

        let dot = try #require(view.stage.sublayers?.first)
        let pulse = try #require(dot.animation(forKey: "ore.pulse") as? CABasicAnimation)
        #expect(pulse.keyPath == "opacity")
        #expect(pulse.autoreverses)
        #expect(pulse.duration == 0.7)
        #expect(dot.cornerRadius == 3)
        // Aligned to whole periods, so separate tabs share one phase.
        let remainder = pulse.beginTime.truncatingRemainder(dividingBy: 1.4)
        #expect(min(remainder, 1.4 - remainder) < 0.001)
    }

    @Test func reducedMotionLeavesTheDotStill() {
        let view = PulsingDotView(frame: .zero)
        view.isAnimated = false
        let (window, attached) = hosted(view, size: NSSize(width: 6, height: 6))
        defer { window.close() }

        #expect(attached.stage.sublayers?.first?.animation(forKey: "ore.pulse") == nil)
    }

    // MARK: - Waveform bars

    @Test func waveformBarsRideEachModesTempoOnTheirOwnPhases() throws {
        let (window, view) = hosted(WaveformBarsView(frame: .zero), size: NSSize(width: 34, height: 20))
        defer { window.close() }
        view.style = .speaking

        let bars = try #require(view.stage.sublayers?.first?.sublayers)
        #expect(bars.count == 5)
        let swings = bars.compactMap { $0.animation(forKey: "ore.wave") as? CABasicAnimation }
        #expect(swings.count == 5)
        #expect(swings.allSatisfy { $0.keyPath == "bounds.size.height" })
        #expect(abs((swings.first?.duration ?? 0) - .pi / 6) < 0.001)
        #expect(Set(swings.map(\.timeOffset)).count == 5)
    }

    @Test func loudnessScalesTheWaveOnlyWhileListening() throws {
        let (window, view) = hosted(WaveformBarsView(frame: .zero), size: NSSize(width: 34, height: 20))
        defer { window.close() }
        let group = try #require(view.stage.sublayers?.first)

        view.style = .listening
        view.level = 1
        #expect(abs(group.transform.m22 - 1) < 0.001)
        view.level = 0
        #expect(abs(group.transform.m22 - WaveformBarsView.listeningScale(0)) < 0.001)

        view.style = .thinking
        #expect(abs(group.transform.m22 - 1) < 0.001)
    }

    @Test func reducedMotionHoldsTheBarsAtRest() throws {
        let view = WaveformBarsView(frame: .zero)
        view.isAnimated = false
        let (window, attached) = hosted(view, size: NSSize(width: 34, height: 20))
        defer { window.close() }

        let bars = try #require(attached.stage.sublayers?.first?.sublayers)
        #expect(bars.allSatisfy { $0.animation(forKey: "ore.wave") == nil })
        #expect(bars.allSatisfy { $0.bounds.height > 4 })
    }
}
