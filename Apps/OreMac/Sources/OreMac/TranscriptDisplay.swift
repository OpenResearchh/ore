import Foundation
import OreProtocol

/// Derives the transcript the table shows from the event-stream rows.
///
/// Completed turns are grouped once and reused. Streaming a later turn used to
/// regroup the whole transcript on every flush — including hashing every
/// finished tool result — which is what made a long session freeze the UI.
enum TranscriptDisplay {
    /// Per-turn cache so a live stream only rebuilds the turn that is still
    /// changing. Invisible to SwiftUI: filling it during a body evaluation
    /// must not schedule another one.
    final class Memo {
        fileprivate struct TurnEntry {
            var turnID: TurnID
            var sourceCount: Int
            var sourceSignature: Int
            var expansionKey: Set<String>
            var expandableIDs: Set<String>
            var output: [TranscriptRow]
        }

        fileprivate var completed: [TurnEntry] = []
        fileprivate var subjects: [String: String] = [:]
        var completedTurnCount: Int { completed.count }

        /// Everything the output depends on. `revision` stands in for `source`:
        /// `ChatState.rows` is `private(set)` and its `didSet` bumps
        /// `rowsRevision` on every mutation path, so nothing can change the rows
        /// without changing the revision. The rest are the inputs that move
        /// independently of the rows.
        fileprivate struct CacheKey: Equatable {
            var revision: Int
            var sourceCount: Int
            var keepLiveTurnExpanded: Bool
            var expanded: Set<String>
            var hidingPlanTurnID: TurnID?
        }

        fileprivate var lastKey: CacheKey?
        fileprivate var lastOutput: [TranscriptRow] = []
    }

    /// - Parameter revision: `ChatState.rowsRevision`, or `nil` to opt out of the
    ///   whole-result cache. Callers that mutate `source` directly (tests) must
    ///   pass `nil`, since without a revision there is no way to notice.
    /// - Parameter keepLiveTurnExpanded: When true, the newest turn stays fully
    ///   visible (no activity-group fold). Pass `ChatState.isTurnActive`, not
    ///   `isBusy` — a turn blocked on a permission is not "busy" for the
    ///   composer, but collapsing its thinking behind a permission card is what
    ///   made the transcript jump.
    static func rows(
        from source: [TranscriptRow],
        keepLiveTurnExpanded: Bool,
        expanded: Set<String>,
        memo: Memo,
        hidingPlanTurnID: TurnID? = nil,
        revision: Int? = nil
    ) -> [TranscriptRow] {
        // The per-turn memo below still walks and hashes every row, which is
        // O(transcript) — fine per stream flush, but this function also runs on
        // any body evaluation that had nothing to do with the rows (the busy
        // flag flipping, a plan arriving, a window resize). Short-circuiting
        // before `prepared` keeps those free.
        let key = revision.map {
            Memo.CacheKey(
                revision: $0,
                sourceCount: source.count,
                keepLiveTurnExpanded: keepLiveTurnExpanded,
                expanded: expanded,
                hidingPlanTurnID: hidingPlanTurnID
            )
        }
        if let key, key == memo.lastKey { return memo.lastOutput }

        let visible = source.compactMap { prepared($0, expanded: expanded, hidingPlanTurnID: hidingPlanTurnID) }
        let activeTurn: TurnID? = keepLiveTurnExpanded ? visible.last?.turnID : nil

        var result: [TranscriptRow] = []
        result.reserveCapacity(visible.count + 8)

        var completed: [Memo.TurnEntry] = []
        completed.reserveCapacity(memo.completed.count + 1)
        var subjects: [String: String] = [:]
        var memoIndex = 0
        var index = visible.startIndex

        while index < visible.endIndex {
            let turnID = visible[index].turnID
            let start = index
            index += 1
            while index < visible.endIndex, visible[index].turnID == turnID {
                index += 1
            }
            let slice = Array(visible[start..<index])
            let isActive = turnID == activeTurn

            if isActive {
                let withSubjects = annotated(slice, subjects: subjects)
                result.append(contentsOf: nestSubagents(
                    present(turn: withSubjects, isActive: true, expanded: expanded),
                    expanded: expanded
                ))
                continue
            }

            let signature = sourceSignature(slice)
            var reusable: Memo.TurnEntry?
            while memoIndex < memo.completed.count {
                let entry = memo.completed[memoIndex]
                memoIndex += 1
                if entry.turnID == turnID {
                    reusable = entry
                    break
                }
            }

            let expandableIDs = reusable?.expandableIDs ?? expandableIDs(in: slice, turnID: turnID)
            let expansionKey = expanded.intersection(expandableIDs)
            if let reusable,
               reusable.sourceCount == slice.count,
               reusable.sourceSignature == signature,
               reusable.expansionKey == expansionKey {
                completed.append(reusable)
                result.append(contentsOf: reusable.output)
                mergeSubjects(from: slice, into: &subjects)
                continue
            }

            let withSubjects = annotated(slice, subjects: subjects)
            let output = nestSubagents(
                present(turn: withSubjects, isActive: false, expanded: expanded),
                expanded: expanded
            )
            let entry = Memo.TurnEntry(
                turnID: turnID,
                sourceCount: slice.count,
                sourceSignature: signature,
                expansionKey: expansionKey,
                expandableIDs: expandableIDs,
                output: output
            )
            completed.append(entry)
            result.append(contentsOf: output)
            mergeSubjects(from: slice, into: &subjects)
        }

        memo.completed = completed
        memo.subjects = subjects
        memo.lastKey = key
        memo.lastOutput = result
        return result
    }

    /// Cheap identity of a source slice: ids and per-row revisions, never text.
    static func sourceSignature(_ rows: [TranscriptRow]) -> Int {
        var hasher = Hasher()
        hasher.combine(rows.count)
        for row in rows {
            hasher.combine(row.id)
            hasher.combine(row.contentRevision)
            hasher.combine(row.isError)
        }
        return hasher.finalize()
    }

    // MARK: - Turn layout

    static func present(
        turn rows: [TranscriptRow],
        isActive: Bool,
        expanded: Set<String>
    ) -> [TranscriptRow] {
        guard !isActive, let turnID = rows.first?.turnID else { return rows }

        let answer = rows.lastIndex {
            $0.kind == .assistantText
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let collapsible = rows.indices.filter { isCollapsible(rows[$0], isAnswer: $0 == answer) }
        guard let firstCollapsibleIndex = collapsible.first else { return rows }

        let hidden = Set(collapsible)
        let collapsed = collapsible.map { rows[$0] }
        let groupID = "activity-\(turnID.rawValue)"
        let groupExpanded = expanded.contains(groupID)

        var group = TranscriptRow(
            id: groupID,
            turnID: turnID,
            kind: .activityGroup,
            text: activitySummary(for: collapsed),
            groupedRows: collapsed,
            isExpanded: groupExpanded
        )
        group.createdAt = collapsed.first?.createdAt ?? Date()
        group.sealDerivedContent()

        var result: [TranscriptRow] = []
        result.reserveCapacity(rows.count - hidden.count + 2)
        for (offset, row) in rows.enumerated() {
            if offset == firstCollapsibleIndex {
                result.append(group)
                if groupExpanded {
                    result.append(contentsOf: collapsed.map { child in
                        var item = child
                        item.isExpanded = expanded.contains(child.id)
                        return item
                    })
                }
                continue
            }
            guard !hidden.contains(offset) else { continue }
            result.append(row)
        }

        var footer = TranscriptRow(
            id: "footer-\(turnID.rawValue)",
            turnID: turnID,
            kind: .turnFooter,
            text: "",
            groupedRows: rows
        )
        footer.createdAt = rows.last?.createdAt ?? Date()
        footer.sealDerivedContent()
        result.append(footer)
        return result
    }

    static func nestSubagents(
        _ rows: [TranscriptRow],
        expanded: Set<String>
    ) -> [TranscriptRow] {
        let childrenByParent = Dictionary(
            grouping: rows.filter { $0.parentToolCallID != nil },
            by: { $0.parentToolCallID! }
        )
        guard !childrenByParent.isEmpty else { return rows }
        let present = Set(rows.compactMap(\.toolCallID))

        var output: [TranscriptRow] = []
        func emit(_ row: TranscriptRow) {
            var item = row
            if item.kind == .toolCall || item.kind == .thinking
                || item.kind == .error || item.kind == .activityGroup {
                item.isExpanded = expanded.contains(row.id)
            }
            if let id = row.toolCallID, let children = childrenByParent[id] {
                item.subagentChildCount = children.count
                output.append(item)
                if item.isExpanded { children.forEach(emit) }
            } else {
                output.append(item)
            }
        }
        for row in rows {
            if let parent = row.parentToolCallID, present.contains(parent) { continue }
            emit(row)
        }
        return output
    }

    static func isCollapsible(_ row: TranscriptRow, isAnswer: Bool) -> Bool {
        switch row.kind {
        case .toolCall, .thinking, .error:
            return true
        case .assistantText:
            return !isAnswer
        case .userMessage, .plan, .divider, .activityGroup, .turnFooter:
            return false
        }
    }

    static func activitySummary(for rows: [TranscriptRow]) -> String {
        // One count for the fold — not tool calls vs thoughts vs notes, which
        // is harness jargon. Issues are drawn separately on the row so they
        // don't hide in a comma list.
        let steps = rows.count
        guard steps > 0 else { return "Activity" }
        return "\(steps) step\(steps == 1 ? "" : "s")"
    }

    // MARK: - Source prep

    private static func prepared(
        _ source: TranscriptRow,
        expanded: Set<String>,
        hidingPlanTurnID: TurnID?
    ) -> TranscriptRow? {
        if source.kind == .plan {
            guard let body = PlanProposalPolicy.normalizedMarkdown(source.text),
                  PlanProposalPolicy.isReadyMarkdown(body)
            else { return nil }
            if source.turnID == hidingPlanTurnID { return nil }
            var row = source
            row.text = body
            return row
        }
        if source.kind == .error, !isMeaningfulError(source.text, result: source.resultText) {
            return nil
        }
        // Machine traffic ORE addressed to the assistant — fleet digests and
        // needs-you notices, with their "reply with exactly SKIP" scaffolding.
        // The persistence layer has always known this isn't conversation
        // (`conversationTranscript(excludingOrigins:)`, used for compaction and
        // turn counts); the transcript was the last place still drawing it, and
        // drawing it as the user's own words at that.
        if source.kind == .userMessage, source.origin == .watch {
            return nil
        }
        // The other half of a digest: a verdict of "nothing worth saying". The
        // token is for ORE, never for a person.
        if source.kind == .assistantText, isSkipVerdict(source.text) {
            return nil
        }
        var row = source
        if row.kind == .toolCall, row.isError,
           !isMeaningfulError(row.text, result: row.resultText) {
            row.isError = false
        }
        if row.kind == .toolCall || row.kind == .thinking || row.kind == .error
            || row.kind == .activityGroup {
            row.isExpanded = expanded.contains(row.id)
        }
        return row
    }

    /// A watch verdict of "nothing here". Matched narrowly — bare `SKIP`, with
    /// at most trailing punctuation — so a reply that merely *mentions* skipping
    /// something is still shown.
    static func isSkipVerdict(_ text: String) -> Bool {
        let value = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        return value.caseInsensitiveCompare("SKIP") == .orderedSame
    }

    private static func isMeaningfulError(_ text: String, result: String?) -> Bool {
        let value = (result?.isEmpty == false ? result! : text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !value.isEmpty && !["null", "nil", "<null>", "(null)", "\"null\""].contains(value)
    }

    private static func annotated(
        _ rows: [TranscriptRow],
        subjects: [String: String]
    ) -> [TranscriptRow] {
        var combined = subjects
        mergeSubjects(from: rows, into: &combined)
        return rows.map { row in
            var item = row
            item.resolvedSubject = taskSubject(for: row, in: combined)
            return item
        }
    }

    private static func mergeSubjects(
        from rows: [TranscriptRow],
        into subjects: inout [String: String]
    ) {
        for row in rows where row.kind == .toolCall {
            guard (row.toolName ?? "").lowercased().hasSuffix("taskcreate"),
                  let subject = row.toolInput?["subject"]?.stringValue,
                  let id = firstNumber(in: row.resultText ?? "")
            else { continue }
            subjects[id] = subject
        }
    }

    private static func taskSubject(
        for row: TranscriptRow,
        in subjects: [String: String]
    ) -> String? {
        guard row.kind == .toolCall,
              (row.toolName ?? "").lowercased().contains("task") else { return nil }
        if let subject = row.toolInput?["subject"]?.stringValue { return subject }
        guard let id = row.toolInput?["taskId"]?.stringValue
            ?? row.toolInput?["taskId"]?.intValue.map(String.init)
        else { return nil }
        return subjects[id]
    }

    private static func firstNumber(in text: String) -> String? {
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static func expandableIDs(in rows: [TranscriptRow], turnID: TurnID) -> Set<String> {
        var ids: Set<String> = ["activity-\(turnID.rawValue)"]
        for row in rows where row.kind == .toolCall || row.kind == .thinking
            || row.kind == .error || row.kind == .activityGroup {
            ids.insert(row.id)
        }
        return ids
    }
}
