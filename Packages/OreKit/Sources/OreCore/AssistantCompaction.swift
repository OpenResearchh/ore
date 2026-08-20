import OreProtocol

/// When an assistant conversation has outgrown what one provider session
/// should be asked to carry, and how the app words that to the user.
///
/// Pure and separate from the engine so the thresholds have a test: getting
/// them wrong is not a crash, it is a seam appearing in the middle of a
/// conversation the user was still having, which no integration test would
/// catch.
public enum AssistantCompaction {
    /// Two triggers, because neither is trustworthy alone. Only Claude Code
    /// reports a context window — Codex and cursor-agent leave it nil, and it
    /// is nil for every harness until the first turn of a session reports
    /// usage. So the turn count is the floor that always fires, and the usage
    /// fraction pulls compaction forward when the harness does say where the
    /// ceiling is.
    public static let turnCeiling = 50
    /// Compact before the harness does. Past this the provider starts dropping
    /// turns on its own, and a summary built from a transcript the model can
    /// no longer see is a summary of nothing.
    public static let usageCeiling = 0.75

    /// The count is of turns the *person* had. A conversation that is 90%
    /// fleet digests has not been going long in any sense the user would
    /// recognise, and compacting it would throw away the little of it that was
    /// theirs. See `MessageOrigin.watch`.
    public static func shouldCompact(userTurnCount: Int, usage: UsageReport?) -> Bool {
        if userTurnCount >= turnCeiling { return true }
        return contextFraction(usage).map { $0 >= usageCeiling } ?? false
    }

    /// Warned before it happens rather than explained afterwards — a seam the
    /// user saw coming reads as ORE working, and one that arrives unannounced
    /// reads as ORE losing their conversation. Both thresholds sit deliberately
    /// below the ceilings above.
    public static func isNearingCompaction(userTurnCount: Int, usage: UsageReport?) -> Bool {
        if userTurnCount >= turnCeiling * 3 / 4 { return true }
        return contextFraction(usage).map { $0 >= usageCeiling * 3 / 4 } ?? false
    }

    /// How much of the model's window this conversation has spent, or nil when
    /// the harness doesn't report one.
    public static func contextFraction(_ usage: UsageReport?) -> Double? {
        guard let usage, let window = usage.contextWindow, window > 0 else { return nil }
        return Double(usage.totalContextTokens) / Double(window)
    }

    /// What the Assistant window puts next to the conversation title.
    public static func lengthLabel(userTurnCount: Int) -> String {
        userTurnCount == 1 ? "1 turn" : "\(userTurnCount) turns"
    }
}
