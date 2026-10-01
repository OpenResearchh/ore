import Foundation

/// One user-facing model with its effort/speed variants collapsed.
///
/// Cursor and Antigravity bake effort (and sometimes Fast) into the model id
/// (`codex-5.3-high-fast`, `gemini-3.8-flash-high`). Claude and Codex keep a
/// single id and advertise efforts separately. The picker and the assistant
/// both need the same grouping so a person sees "Codex 5.3" and an effort
/// chip, not eight radio rows.
public struct ModelFamily: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var description: String
    public var isDefault: Bool
    public var variants: [AgentModel]
    /// Distinct efforts encoded in variant ids, ordered along the effort ladder.
    /// Empty when the family is a single id whose efforts come from
    /// `AgentModel.supportedReasoningEfforts`.
    public var encodedEfforts: [ReasoningEffort]
    public var supportsFast: Bool

    public init(
        id: String,
        displayName: String,
        description: String,
        isDefault: Bool,
        variants: [AgentModel],
        encodedEfforts: [ReasoningEffort],
        supportsFast: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.variants = variants
        self.encodedEfforts = encodedEfforts
        self.supportsFast = supportsFast
    }

    public var defaultVariant: AgentModel {
        variants.first(where: \.isDefault)
            ?? variants.first { ModelVariantCatalog.parse($0).effort == nil && !ModelVariantCatalog.parse($0).fast }
            ?? variants[0]
    }

    public func resolve(effort: ReasoningEffort?, fast: Bool) -> AgentModel {
        let parsed = variants.map { ($0, ModelVariantCatalog.parse($0)) }
        let want = ModelVariantCatalog.normalized(effort)
        if let match = parsed.first(where: {
            ModelVariantCatalog.normalized($0.1.effort) == want && $0.1.fast == fast
        }) {
            return match.0
        }
        if let match = parsed.first(where: { ModelVariantCatalog.normalized($0.1.effort) == want }) {
            return match.0
        }
        if fast, let match = parsed.first(where: { $0.1.fast && $0.1.effort == nil }) {
            return match.0
        }
        return defaultVariant
    }

    public func isFast(_ modelID: String?) -> Bool {
        guard let modelID, let variant = variants.first(where: { $0.id == modelID }) else {
            return false
        }
        return ModelVariantCatalog.parse(variant).fast
    }

    public func encodedEffort(of modelID: String?) -> ReasoningEffort? {
        guard let modelID, let variant = variants.first(where: { $0.id == modelID }) else {
            return nil
        }
        return ModelVariantCatalog.normalized(ModelVariantCatalog.parse(variant).effort)
    }
}

public enum ModelVariantCatalog {
    public struct ParsedVariant: Sendable, Equatable {
        public var familyID: String
        public var familyName: String
        public var effort: ReasoningEffort?
        public var fast: Bool
    }

    public static func families(from models: [AgentModel]) -> [ModelFamily] {
        var order: [String] = []
        var grouped: [String: [AgentModel]] = [:]
        for model in models {
            let key = parse(model).familyID
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(model)
        }
        return order.compactMap { key in
            guard let variants = grouped[key], let first = variants.first else { return nil }
            let parsed = variants.map(parse)
            var seen = Set<ReasoningEffort>()
            var efforts: [ReasoningEffort] = []
            for item in parsed {
                let effort = normalized(item.effort)
                if variants.count > 1 || item.effort != nil {
                    if seen.insert(effort).inserted { efforts.append(effort) }
                }
            }
            if variants.count == 1 { efforts = [] }
            efforts.sort { ladderIndex($0) < ladderIndex($1) }
            let names = parsed.map(\.familyName)
            let displayName = mostCommon(names) ?? parse(first).familyName
            let description = variants.first(where: { !$0.description.isEmpty })?.description ?? ""
            return ModelFamily(
                id: key,
                displayName: displayName,
                description: description,
                isDefault: variants.contains(where: \.isDefault),
                variants: variants,
                encodedEfforts: efforts,
                supportsFast: parsed.contains(where: \.fast)
            )
        }
    }

    public static func family(containing modelID: String?, in models: [AgentModel]) -> ModelFamily? {
        let all = families(from: models)
        guard let modelID else { return all.first(where: \.isDefault) ?? all.first }
        return all.first { family in family.variants.contains { $0.id == modelID } }
    }

    public static func parse(_ model: AgentModel) -> ParsedVariant {
        let id = parseIdentifier(model.id)
        return ParsedVariant(
            familyID: id.family,
            familyName: stripDisplayName(model.displayName),
            effort: id.effort,
            fast: id.fast
        )
    }

    static func normalized(_ effort: ReasoningEffort?) -> ReasoningEffort {
        effort ?? .medium
    }

    /// Map a family id plus effort/Fast onto the catalog row that actually
    /// carries them. Cursor has no separate `--effort`; the suffix is the setting.
    public static func align(
        model: String?,
        effort: ReasoningEffort?,
        in models: [AgentModel]
    ) -> (model: String?, effort: ReasoningEffort?) {
        if model == nil, effort == nil { return (nil, nil) }
        guard let family = family(containing: model, in: models),
              !family.encodedEfforts.isEmpty
        else { return (model, effort) }
        let fast = family.isFast(model)
        let chosen = effort ?? family.encodedEffort(of: model)
        let resolved = family.resolve(effort: chosen, fast: fast)
        return (resolved.id, chosen ?? family.encodedEffort(of: resolved.id))
    }

    public static func remappedID(
        current: String?,
        effort: ReasoningEffort?,
        in models: [AgentModel]
    ) -> String? {
        let aligned = align(model: current, effort: effort, in: models)
        guard let next = aligned.model, next != current else { return nil }
        return next
    }

    public static func parseIdentifier(_ id: String) -> (family: String, effort: ReasoningEffort?, fast: Bool) {
        var rest = id
        var fast = false
        if rest.lowercased().hasSuffix("-fast") {
            fast = true
            rest.removeLast(5)
        }
        let suffixes: [(String, ReasoningEffort)] = [
            ("-extra-high", .xhigh),
            ("-xhigh", .xhigh),
            ("-medium", .medium),
            ("-high", .high),
            ("-low", .low),
            ("-max", .max),
            ("-none", .none),
        ]
        let lower = rest.lowercased()
        for (suffix, effort) in suffixes {
            if lower.hasSuffix(suffix) {
                rest.removeLast(suffix.count)
                return (rest, effort, fast)
            }
        }
        return (rest, nil, fast)
    }

    static func stripDisplayName(_ name: String) -> String {
        var rest = name.trimmingCharacters(in: .whitespaces)
        if rest.lowercased().hasSuffix(" fast") {
            rest = String(rest.dropLast(5)).trimmingCharacters(in: .whitespaces)
        }
        let parenthetical = [
            " (Extra High)", " (X High)", " (High)", " (Medium)", " (Low)", " (Max)", " (None)",
        ]
        for suffix in parenthetical {
            if rest.lowercased().hasSuffix(suffix.lowercased()) {
                rest = String(rest.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let trailing = [" Extra High", " X High", " High", " Medium", " Low", " Max", " None"]
        for suffix in trailing {
            if rest.lowercased().hasSuffix(suffix.lowercased()) {
                rest = String(rest.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return rest.isEmpty ? name : rest
    }

    private static func ladderIndex(_ effort: ReasoningEffort) -> Int {
        ReasoningEffort.allCases.firstIndex(of: effort) ?? 0
    }

    private static func mostCommon(_ names: [String]) -> String? {
        var counts: [String: Int] = [:]
        for name in names where !name.isEmpty { counts[name, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
}
