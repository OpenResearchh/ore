import AppKit
import SwiftUI

/// Decorative motion the render server animates on its own.
///
/// A `TimelineView` loop wakes the main thread on every tick, re-evaluates a
/// body and commits a transaction — and at 12 Hz the motion is visibly
/// stepped. A repeating `CAAnimation` on a layer is handed to the render
/// server once; from then on this process does nothing per frame and the
/// motion runs at the display's own rate.
///
/// Everything that moves hangs off `stage`, so pausing is one `speed = 0`
/// that freezes every animation exactly where it is. The view is flipped so
/// that, as in SwiftUI, y grows downward and a positive rotation reads
/// clockwise on screen.
class RenderServerAnimationView: NSView {
    let stage = CALayer()
    private static let noImplicitAnimation: [String: CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
        "contents": NSNull(), "colors": NSNull(), "path": NSNull(),
        "strokeColor": NSNull(), "cornerRadius": NSNull(), "borderWidth": NSNull(),
        "backgroundColor": NSNull(), "opacity": NSNull(), "transform": NSNull(),
        "sublayers": NSNull(), "hidden": NSNull(),
    ]

    var isPaused = false {
        didSet { if isPaused != oldValue { applyPause() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        Self.quiet(stage)
        layer?.addSublayer(stage)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemColorsDidChange),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Decoration only; whatever is underneath keeps the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func quiet(_ layer: CALayer) {
        layer.actions = noImplicitAnimation
    }

    /// AppKit only lays out on its own schedule; the composer grows as you
    /// type, and the layers have to follow its frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        layoutContent(in: bounds)
        CATransaction.commit()
    }

    /// Runs inside a transaction with implicit animations disabled.
    func layoutContent(in bounds: CGRect) {}

    /// Resolve colours against the view's appearance. Called on attach, on
    /// appearance change and when the system accent changes.
    func updateColors() {}

    /// Layers added by hand don't inherit the backing scale the way AppKit's
    /// own do, and a shape layer at 1× draws a soft edge on a Retina screen.
    func updateContentsScale(_ scale: CGFloat) {
        stage.contentsScale = scale
    }

    /// Removes and re-adds this view's animations. Runs on attach — a layer
    /// that leaves its window loses them — and whenever their shape changes.
    func installAnimations() {}

    /// For property observers: re-install now if attached; attaching will
    /// otherwise do it.
    func animationsDidChange() {
        guard window != nil else { return }
        installAnimations()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        updateContentsScale(window.backingScaleFactor)
        updateColors()
        installAnimations()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { updateContentsScale(window.backingScaleFactor) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    @objc private func systemColorsDidChange() {
        updateColors()
    }

    /// The usual freeze-and-resume dance (QA1673): a paused layer holds its
    /// current local time, and resuming shifts `beginTime` by however long it
    /// stood still so the motion carries on from where it stopped.
    private func applyPause() {
        if isPaused {
            guard stage.speed != 0 else { return }
            stage.timeOffset = stage.convertTime(CACurrentMediaTime(), from: nil)
            stage.speed = 0
        } else if stage.speed == 0 {
            let pausedAt = stage.timeOffset
            stage.speed = 1
            stage.timeOffset = 0
            stage.beginTime = 0
            stage.beginTime = stage.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }
}

/// A layer spinning forever about the view's centre, kept as a square on the
/// view's diagonal so nothing rotates out from under a mask.
class RenderServerSpinnerView: RenderServerAnimationView {
    let spinner: CALayer
    private static let rotationKey = "ore.spin"

    var period: TimeInterval = 1 {
        didSet { if period != oldValue { animationsDidChange() } }
    }

    init(spinner: CALayer) {
        self.spinner = spinner
        super.init(frame: .zero)
        Self.quiet(spinner)
        stage.addSublayer(spinner)
    }

    override func layoutContent(in bounds: CGRect) {
        let side = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot()
        spinner.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func updateContentsScale(_ scale: CGFloat) {
        super.updateContentsScale(scale)
        spinner.contentsScale = scale
    }

    override func installAnimations() {
        spinner.removeAnimation(forKey: Self.rotationKey)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        spinner.add(spin, forKey: Self.rotationKey)
    }
}

// MARK: - Composer busy border

/// The accent highlight that sweeps around the composer while the agent
/// works: a conic gradient spinning under a ring-shaped mask. The mask is a
/// layer border with a continuous corner curve, which is the same curve
/// SwiftUI's `.continuous` rounded rectangle draws.
final class SweepingBorderView: RenderServerSpinnerView {
    private let gradient = CAGradientLayer()
    private let ring = CALayer()

    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    var lineWidth: CGFloat = 1.75 {
        didSet { if lineWidth != oldValue { needsLayout = true } }
    }

    /// Alpha at each evenly spaced stop; the peak is the highlight.
    private static let stops: [CGFloat] = [0, 0.15, 0.85, 0.15, 0]

    init() {
        super.init(spinner: gradient)
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.25, 0.5, 0.75, 1]
        Self.quiet(ring)
        ring.borderColor = NSColor.white.cgColor
        ring.cornerCurve = .continuous
        layer?.mask = ring
    }

    override func layoutContent(in bounds: CGRect) {
        super.layoutContent(in: bounds)
        ring.frame = bounds
        ring.cornerRadius = cornerRadius
        ring.borderWidth = lineWidth
    }

    override func updateContentsScale(_ scale: CGFloat) {
        super.updateContentsScale(scale)
        ring.contentsScale = scale
    }

    override func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            gradient.colors = Self.stops.map { accent.withAlphaComponent($0).cgColor }
        }
    }
}

struct SweepingBorder: NSViewRepresentable {
    let cornerRadius: CGFloat
    var lineWidth: CGFloat = 1.75
    var period: TimeInterval = 2.4
    let isPaused: Bool

    func makeNSView(context: Context) -> SweepingBorderView { SweepingBorderView() }

    func updateNSView(_ view: SweepingBorderView, context: Context) {
        view.cornerRadius = cornerRadius
        view.lineWidth = lineWidth
        view.period = period
        view.isPaused = isPaused
    }
}

// MARK: - Orbiting arc

/// A short arc orbiting inside its frame: the sidebar's row-scale version of
/// the composer sweep. The stroke is centred on a circle inscribed in the
/// view, exactly as `Circle().trim().stroke()` lays it out.
final class OrbitingArcView: RenderServerSpinnerView {
    private let arc = CAShapeLayer()

    var color: NSColor = .controlAccentColor {
        didSet { if color != oldValue { updateColors() } }
    }

    var lineWidth: CGFloat = 2 {
        didSet { if lineWidth != oldValue { needsLayout = true } }
    }

    /// Fraction of the circle the arc covers.
    var fraction: CGFloat = 0.32 {
        didSet { if fraction != oldValue { needsLayout = true } }
    }

    init() {
        super.init(spinner: arc)
        arc.fillColor = nil
        arc.lineCap = .round
    }

    override func layoutContent(in bounds: CGRect) {
        super.layoutContent(in: bounds)
        let diameter = min(bounds.width, bounds.height)
        let center = CGPoint(x: arc.bounds.midX, y: arc.bounds.midY)
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: diameter / 2,
            startAngle: 0,
            endAngle: 2 * .pi * fraction,
            clockwise: false
        )
        arc.path = path
        arc.lineWidth = lineWidth
    }

    override func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = color.cgColor
        }
    }
}

struct OrbitingArc: NSViewRepresentable {
    let color: Color
    var lineWidth: CGFloat = 2
    var fraction: CGFloat = 0.32
    var period: TimeInterval = 1.6
    let isPaused: Bool

    func makeNSView(context: Context) -> OrbitingArcView { OrbitingArcView() }

    func updateNSView(_ view: OrbitingArcView, context: Context) {
        view.color = NSColor(color)
        view.lineWidth = lineWidth
        view.fraction = fraction
        view.period = period
        view.isPaused = isPaused
    }
}

// MARK: - Pulsing dot

/// A dot breathing between faint and full: the busy marker on a working tab.
/// A cosine in the old timeline; an eased, auto-reversing opacity here, which
/// is the same curve.
final class PulsingDotView: RenderServerAnimationView {
    private let dot = CALayer()
    private static let pulseKey = "ore.pulse"

    var color: NSColor = .controlAccentColor {
        didSet { if color != oldValue { updateColors() } }
    }

    /// One full breath, faint to full and back.
    var period: TimeInterval = 1.4 {
        didSet { if period != oldValue { animationsDidChange() } }
    }

    /// Off under Reduce Motion: the dot sits at full strength.
    var isAnimated = true {
        didSet { if isAnimated != oldValue { animationsDidChange() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.quiet(dot)
        stage.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutContent(in bounds: CGRect) {
        let diameter = min(bounds.width, bounds.height)
        dot.frame = CGRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        dot.cornerRadius = diameter / 2
    }

    override func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = color.cgColor
        }
    }

    override func installAnimations() {
        dot.removeAnimation(forKey: Self.pulseKey)
        guard isAnimated else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3
        pulse.toValue = 1.0
        pulse.duration = period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        // Started on a whole period of the shared media clock, so every busy
        // tab breathes in step — as they did when the phase came from the
        // wall clock.
        let now = dot.convertTime(CACurrentMediaTime(), from: nil)
        pulse.beginTime = (now / period).rounded(.down) * period
        dot.add(pulse, forKey: Self.pulseKey)
    }
}

struct PulsingDot: NSViewRepresentable {
    var color: NSColor = .controlAccentColor
    var period: TimeInterval = 1.4
    let isAnimated: Bool
    let isPaused: Bool

    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView(frame: .zero) }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.color = color
        view.period = period
        view.isAnimated = isAnimated
        view.isPaused = isPaused
    }
}

// MARK: - Waveform bars

/// Five capsules riding one wave, each on its own phase: the voice pill's
/// listening, speaking and thinking figure.
///
/// Each bar's height is a render-server animation. Loudness is the only live
/// input, and it lands as one scale on the group at the microphone's own
/// cadence, so a long narration or a held mic costs the main thread a value
/// write per level tick rather than a SwiftUI pass per frame.
final class WaveformBarsView: RenderServerAnimationView {
    enum Style: Equatable {
        case listening
        case thinking
        case speaking
    }

    private let group = CALayer()
    private let bars = (0..<5).map { _ in CALayer() }
    private static let waveKey = "ore.wave"
    private static let barWidth: CGFloat = 3.5
    private static let barSpacing: CGFloat = 3
    private static let minHeight: CGFloat = 4
    private var appliedScale: CGFloat = 1

    var style: Style = .thinking {
        didSet {
            guard style != oldValue else { return }
            animationsDidChange()
            applyLevel()
        }
    }

    /// Microphone loudness, 0…1. Only read while listening.
    var level: Double = 0 {
        didSet { if level != oldValue { applyLevel() } }
    }

    var isAnimated = true {
        didSet { if isAnimated != oldValue { animationsDidChange() } }
    }

    var color: NSColor = .controlAccentColor {
        didSet { if color != oldValue { updateColors() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.quiet(group)
        stage.addSublayer(group)
        for bar in bars {
            Self.quiet(bar)
            bar.cornerRadius = Self.barWidth / 2
            group.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The wave each style rides, in the old timeline's terms: bars swing
    /// from 4 pt to `maxHeight` at `omega` radians a second, each `phase`
    /// radians behind the one before.
    private struct Wave {
        var maxHeight: CGFloat
        var omega: Double
        var phase: Double
    }

    private var wave: Wave {
        switch style {
        case .listening: Wave(maxHeight: 20, omega: 9, phase: 1.7)
        case .speaking: Wave(maxHeight: 15, omega: 6, phase: 1.3)
        case .thinking: Wave(maxHeight: 9, omega: 2.4, phase: 0.35)
        }
    }

    /// Silence still draws a quiet line rather than nothing.
    nonisolated static func listeningScale(_ level: Double) -> CGFloat {
        CGFloat(0.3 + min(max(level, 0), 1) * 0.7)
    }

    override func layoutContent(in bounds: CGRect) {
        group.bounds = CGRect(origin: .zero, size: bounds.size)
        group.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let figureWidth = Self.barWidth * 5 + Self.barSpacing * 4
        let startX = (bounds.width - figureWidth) / 2 + Self.barWidth / 2
        for (index, bar) in bars.enumerated() {
            bar.bounds.size.width = Self.barWidth
            bar.position = CGPoint(
                x: startX + CGFloat(index) * (Self.barWidth + Self.barSpacing),
                y: bounds.midY
            )
        }
        setRestingHeights()
    }

    private func setRestingHeights() {
        let resting = isAnimated ? Self.minHeight : (Self.minHeight + wave.maxHeight) / 2
        for bar in bars {
            bar.bounds.size = CGSize(width: Self.barWidth, height: resting)
        }
    }

    override func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = color.cgColor
            for bar in bars { bar.backgroundColor = fill }
        }
    }

    override func installAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setRestingHeights()
        CATransaction.commit()
        let wave = wave
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: Self.waveKey)
            guard isAnimated else { continue }
            let swing = CABasicAnimation(keyPath: "bounds.size.height")
            swing.fromValue = Self.minHeight
            swing.toValue = wave.maxHeight
            // Half a sine cycle up, half back down.
            swing.duration = .pi / wave.omega
            swing.autoreverses = true
            swing.repeatCount = .infinity
            swing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            swing.isRemovedOnCompletion = false
            let cycle = 2 * swing.duration
            swing.timeOffset = (Double(index) * wave.phase / wave.omega)
                .truncatingRemainder(dividingBy: cycle)
            bar.add(swing, forKey: Self.waveKey)
        }
    }

    private func applyLevel() {
        let target = style == .listening ? Self.listeningScale(level) : 1
        guard abs(appliedScale - target) > 0.005 else { return }
        let from = (group.presentation()?.value(forKeyPath: "transform.scale.y") as? NSNumber)
            .map { CGFloat($0.doubleValue) } ?? appliedScale
        appliedScale = target
        group.transform = CATransform3DMakeScale(1, target, 1)
        guard isAnimated, window != nil else { return }
        // Eased across roughly one mic tick, so loudness glides.
        let ease = CABasicAnimation(keyPath: "transform.scale.y")
        ease.fromValue = from
        ease.toValue = target
        ease.duration = 0.12
        ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.add(ease, forKey: "ore.level")
    }
}

struct WaveformBarsLayer: NSViewRepresentable {
    let style: WaveformBarsView.Style
    let level: Double
    let isAnimated: Bool

    func makeNSView(context: Context) -> WaveformBarsView { WaveformBarsView(frame: .zero) }

    func updateNSView(_ view: WaveformBarsView, context: Context) {
        view.isAnimated = isAnimated
        view.style = style
        view.level = level
    }
}

#Preview("Busy border") {
    VStack(spacing: 24) {
        RoundedRectangle(cornerRadius: OreTheme.cardRadius, style: .continuous)
            .fill(.quaternary)
            .overlay { SweepingBorder(cornerRadius: OreTheme.cardRadius, isPaused: false) }
            .frame(width: 520, height: 96)
        RoundedRectangle(cornerRadius: OreTheme.cardRadius, style: .continuous)
            .fill(.quaternary)
            .overlay { SweepingBorder(cornerRadius: OreTheme.cardRadius, isPaused: true) }
            .frame(width: 520, height: 96)
    }
    .padding(40)
}

#Preview("Orbiting arc, dot, waveform") {
    HStack(spacing: 24) {
        Circle().fill(.quaternary)
            .overlay { OrbitingArc(color: OreTheme.Status.running, isPaused: false).padding(-2.5) }
            .frame(width: 28, height: 28)
        PulsingDot(isAnimated: true, isPaused: false)
            .frame(width: 6, height: 6)
        WaveformBarsLayer(style: .speaking, level: 0, isAnimated: true)
            .frame(width: 34, height: 20)
        WaveformBarsLayer(style: .listening, level: 0.7, isAnimated: true)
            .frame(width: 34, height: 20)
    }
    .padding(40)
}
