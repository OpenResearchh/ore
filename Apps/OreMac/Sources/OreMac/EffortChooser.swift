import OreProtocol
import SwiftUI

struct EffortChooser: View {
    @Binding var selection: ReasoningEffort
    let efforts: [ReasoningEffort]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var scale: EffortPickerScale { EffortPickerScale(efforts: efforts) }
    private var accent: Color { selection == .adaptive ? .cyan : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: selection == .adaptive ? "sparkles" : "bolt.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .oreGlassSurface(.capsule, tint: accent.opacity(0.12), elevation: .inset)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reasoning effort")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(efforts.isEmpty ? "Unavailable" : selection.displayName)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .contentTransition(.numericText())
                }
                Spacer()
            }

            Text(efforts.isEmpty
                 ? "This model does not offer an effort control."
                 : selection.effortExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)

            if scale.sliderRange != nil {
                effortSlider
                HStack(spacing: 0) {
                    ForEach(efforts, id: \.self) { effort in
                        Button {
                            choose(effort)
                        } label: {
                            Text(effort == .xhigh ? "X High" : effort.displayName)
                                .font(.system(size: 10, weight: selection == effort ? .bold : .medium))
                                .foregroundStyle(selection == effort ? accent : .secondary)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(selection == effort ? accent.opacity(0.12) : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(effort.displayName)
                        .accessibilityAddTraits(selection == effort ? .isSelected : [])
                        .help(effort.effortExplanation)
                    }
                }
                HStack {
                    Label("Faster", systemImage: "hare")
                    Spacer()
                    Label("Deeper", systemImage: "sparkles")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if !efforts.isEmpty {
                Label("Selected automatically for this model", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 340)
        .oreGlassSurface(.rect(cornerRadius: 22), elevation: .popover)
        .padding(6)
    }

    private var effortSlider: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 32)
            let fraction = scale.value(for: selection) / Double(max(1, efforts.count - 1))
            let position = travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(OreTheme.subduedFill)
                Capsule()
                    .fill(LinearGradient(colors: [.red.opacity(0.75), .orange, .yellow], startPoint: .leading, endPoint: .trailing))
                    .frame(width: position + 32)
                    .shadow(color: reduceTransparency ? .clear : accent.opacity(0.4), radius: 9)
                ForEach(efforts.indices, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(0.55))
                        .frame(width: 4, height: 4)
                        .offset(x: 14 + travel * Double(index) / Double(max(1, efforts.count - 1)))
                }
                Circle()
                    .fill(.white)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .offset(x: position + 1)
            }
            .frame(height: 32)
            .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let fraction = min(1, max(0, (value.location.x - 16) / travel))
                if let effort = scale.selection(at: fraction * Double(efforts.count - 1)) {
                    choose(effort)
                }
            })
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(selection.displayName)
        .accessibilityHint("Adjust from faster responses to deeper reasoning")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .right, .up: step(1)
            case .left, .down: step(-1)
            default: break
            }
        }
    }

    private func step(_ direction: Double) {
        if let effort = scale.selection(at: scale.value(for: selection) + direction) {
            choose(effort)
        }
    }

    private func choose(_ effort: ReasoningEffort) {
        guard selection != effort else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selection = effort }
    }
}

private extension ReasoningEffort {
    var effortExplanation: String {
        switch self {
        case .none: "Respond directly without extra reasoning. Best for straightforward requests."
        case .low: "Keep reasoning brief for quick questions and small edits."
        case .medium: "Balance response speed with care for everyday coding tasks."
        case .high: "Spend more time reasoning through complex changes and tricky bugs."
        case .xhigh: "Explore harder problems more thoroughly, with a longer wait."
        case .max: "Use the greatest available reasoning effort for the most demanding tasks."
        case .adaptive: "Let the model choose how much reasoning the task needs."
        }
    }
}
