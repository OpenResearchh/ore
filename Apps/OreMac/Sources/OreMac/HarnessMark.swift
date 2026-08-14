import AppKit
import OreProtocol
import SwiftUI

/// The real provider marks, shared by tabs, model controls, activity states,
/// and settings. Keeping them here prevents each screen from inventing a new
/// generic SF Symbol for the same agent.
struct HarnessMark: View {
    let harness: HarnessKind
    var size: CGFloat = 16
    var isMuted = false

    var body: some View {
        Group {
            switch harness {
            case .claudeCode:
                brandImage(HarnessBrandAssets.claude)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))

            case .codex:
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(Color.black.opacity(isMuted ? 0.65 : 1))
                    brandImage(HarnessBrandAssets.codex)
                        .padding(size * 0.13)
                }

            case .cursorAgent:
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(Color.black.opacity(isMuted ? 0.65 : 1))
                    brandImage(HarnessBrandAssets.cursor)
                        .padding(size * 0.2)
                }
            }
        }
        .frame(width: size, height: size)
        .saturation(isMuted ? 0 : 1)
        .opacity(isMuted ? 0.72 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func brandImage(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.58, weight: .semibold))
        }
    }
}

@MainActor
private enum HarnessBrandAssets {
    static let claude = load("claude")
    static let codex = load("codex")
    static let cursor = load("cursor")

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "HarnessIcons"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Captures a deliberate wheel gesture only while the pointer is over the host
/// control. Trackpads must travel a meaningful distance and mouse wheels need
/// three detents before a level changes. Momentum never changes a second level.
struct ScrollWheelAdjuster: NSViewRepresentable {
    var onProgress: (CGFloat) -> Void
    var onStep: (Int) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onStep: onStep)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.host = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onProgress = onProgress
        context.coordinator.onStep = onStep
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var host: NSView?
        var onProgress: (CGFloat) -> Void
        var onStep: (Int) -> Bool

        private var monitor: Any?
        private var accumulator = EffortScrollAccumulator()

        init(
            onProgress: @escaping (CGFloat) -> Void,
            onStep: @escaping (Int) -> Bool
        ) {
            self.onProgress = onProgress
            self.onStep = onStep
        }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let host = self.host, event.window === host.window else { return event }
                let location = host.convert(event.locationInWindow, from: nil)
                guard host.bounds.contains(location) else { return event }

                // Inertial scrolling after the fingers leave the trackpad must
                // never make an extra, disconnected effort change.
                if !event.momentumPhase.isEmpty {
                    self.resetGesture()
                    return nil
                }
                if event.phase == .began { self.resetGesture() }

                let rawDelta = event.scrollingDeltaY
                guard abs(rawDelta) > 0.01 else { return nil }
                let update = self.accumulator.consume(
                    delta: rawDelta,
                    precise: event.hasPreciseScrollingDeltas
                )
                self.onProgress(update.progress)
                self.scheduleReset()

                guard let step = update.step else { return nil }

                let didChange = self.onStep(step)
                if didChange {
                    NSHapticFeedbackManager.defaultPerformer.perform(
                        .levelChange,
                        performanceTime: .now
                    )
                }
                self.onProgress(0)
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(resetAfterPause),
                object: nil
            )
        }

        private func scheduleReset() {
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(resetAfterPause),
                object: nil
            )
            perform(#selector(resetAfterPause), with: nil, afterDelay: 0.34)
        }

        @objc private func resetAfterPause() { resetGesture() }

        private func resetGesture() {
            accumulator.reset()
            onProgress(0)
        }
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Small, deterministic state machine behind the gesture. Keeping threshold
/// math out of NSEvent handling makes accidental-change behavior testable.
struct EffortScrollAccumulator {
    private var accumulatedDelta: CGFloat = 0
    private var direction = 0

    mutating func consume(delta: CGFloat, precise: Bool) -> (progress: CGFloat, step: Int?) {
        let nextDirection = delta > 0 ? 1 : -1
        if direction != 0, nextDirection != direction { accumulatedDelta = 0 }
        direction = nextDirection

        let threshold: CGFloat = precise ? 34 : 3
        accumulatedDelta += precise ? delta : CGFloat(nextDirection)
        let progress = min(1, abs(accumulatedDelta) / threshold) * CGFloat(nextDirection)
        guard abs(accumulatedDelta) >= threshold else { return (progress, nil) }

        accumulatedDelta = 0
        return (progress, nextDirection)
    }

    mutating func reset() {
        accumulatedDelta = 0
        direction = 0
    }
}
