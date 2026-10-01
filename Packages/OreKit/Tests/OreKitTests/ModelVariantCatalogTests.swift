import Foundation
import Testing

@testable import OreProtocol

struct ModelVariantCatalogTests {
    @Test func cursorCodexVariantsCollapseToOneFamily() {
        let models = [
            AgentModel(id: "gpt-5.3-codex-low", displayName: "Codex 5.3 Low"),
            AgentModel(id: "gpt-5.3-codex-low-fast", displayName: "Codex 5.3 Low Fast"),
            AgentModel(id: "gpt-5.3-codex", displayName: "Codex 5.3", isDefault: true),
            AgentModel(id: "gpt-5.3-codex-fast", displayName: "Codex 5.3 Fast"),
            AgentModel(id: "gpt-5.3-codex-high", displayName: "Codex 5.3 High"),
            AgentModel(id: "gpt-5.3-codex-high-fast", displayName: "Codex 5.3 High Fast"),
            AgentModel(id: "gpt-5.3-codex-xhigh", displayName: "Codex 5.3 Extra High"),
            AgentModel(id: "gpt-5.3-codex-xhigh-fast", displayName: "Codex 5.3 Extra High Fast"),
            AgentModel(id: "auto", displayName: "Auto"),
        ]
        let families = ModelVariantCatalog.families(from: models)
        #expect(families.map(\.id) == ["gpt-5.3-codex", "auto"])
        let codex = families[0]
        #expect(codex.displayName == "Codex 5.3")
        #expect(codex.encodedEfforts == [.low, .medium, .high, .xhigh])
        #expect(codex.supportsFast)
        #expect(codex.resolve(effort: .high, fast: false).id == "gpt-5.3-codex-high")
        #expect(codex.resolve(effort: .high, fast: true).id == "gpt-5.3-codex-high-fast")
        #expect(codex.resolve(effort: .medium, fast: false).id == "gpt-5.3-codex")
        #expect(codex.resolve(effort: nil, fast: true).id == "gpt-5.3-codex-fast")
    }

    @Test func antigravityFlashVariantsShareAFamily() {
        let models = [
            AgentModel(id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash (High)", isDefault: true),
            AgentModel(id: "gemini-3.8-flash-medium", displayName: "Gemini 3.8 Flash (Medium)"),
            AgentModel(id: "gemini-3.8-flash-low", displayName: "Gemini 3.8 Flash (Low)"),
            AgentModel(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6 (Thinking)"),
        ]
        let families = ModelVariantCatalog.families(from: models)
        #expect(families.map(\.displayName) == ["Gemini 3.8 Flash", "Claude Sonnet 4.6 (Thinking)"])
        #expect(families[0].encodedEfforts == [.low, .medium, .high])
        #expect(families[1].encodedEfforts.isEmpty)
        #expect(families[0].resolve(effort: .low, fast: false).id == "gemini-3.8-flash-low")
    }

    @Test func aClaudeModelStaysASingleRow() {
        let models = [
            AgentModel(
                id: "claude-sonnet-5[1m]", displayName: "Sonnet 5 · 1M", isDefault: true,
                supportedReasoningEfforts: ["low", "medium", "high"]
            )
        ]
        let family = ModelVariantCatalog.families(from: models)[0]
        #expect(family.variants.count == 1)
        #expect(family.encodedEfforts.isEmpty)
        #expect(!family.supportsFast)
    }

    @Test func familyLookupFindsTheVariant() {
        let models = [
            AgentModel(id: "cursor-grok-4.6-high", displayName: "Cursor Grok 4.6"),
            AgentModel(id: "composer-2.5", displayName: "Composer 2.5"),
        ]
        let family = ModelVariantCatalog.family(containing: "cursor-grok-4.6-high", in: models)
        #expect(family?.id == "cursor-grok-4.6")
        #expect(family?.encodedEffort(of: "cursor-grok-4.6-high") == .high)
    }

    @Test func alignRemapsCursorEffortAndKeepsFast() {
        let models = [
            AgentModel(id: "gpt-5.3-codex", displayName: "Codex 5.3", isDefault: true),
            AgentModel(id: "gpt-5.3-codex-high", displayName: "Codex 5.3 High"),
            AgentModel(id: "gpt-5.3-codex-high-fast", displayName: "Codex 5.3 High Fast"),
            AgentModel(id: "gpt-5.3-codex-fast", displayName: "Codex 5.3 Fast"),
        ]
        let high = ModelVariantCatalog.align(
            model: "gpt-5.3-codex", effort: .high, in: models
        )
        #expect(high.model == "gpt-5.3-codex-high")
        #expect(high.effort == .high)
        let fastHigh = ModelVariantCatalog.align(
            model: "gpt-5.3-codex-fast", effort: .high, in: models
        )
        #expect(fastHigh.model == "gpt-5.3-codex-high-fast")
        #expect(ModelVariantCatalog.remappedID(
            current: "gpt-5.3-codex-high", effort: .high, in: models
        ) == nil)
    }

    @Test func alignLeavesASingleClaudeIdAlone() {
        let models = [
            AgentModel(
                id: "claude-sonnet-5[1m]", displayName: "Sonnet 5 · 1M",
                supportedReasoningEfforts: ["low", "medium", "high"]
            )
        ]
        let aligned = ModelVariantCatalog.align(
            model: "claude-sonnet-5[1m]", effort: .high, in: models
        )
        #expect(aligned.model == "claude-sonnet-5[1m]")
        #expect(aligned.effort == .high)
    }
}
