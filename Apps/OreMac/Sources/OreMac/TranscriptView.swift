import AppKit
import OreProtocol
import SwiftUI

/// The chat transcript.
///
/// AppKit rather than SwiftUI, from day one and on purpose. This is the surface
/// the user stares at while an agent works, it grows to thousands of rows in a
/// long session, and it mutates constantly while text streams. A SwiftUI `List`
/// re-evaluates its body on every change, and a transcript is exactly the shape
/// that makes that expensive.
///
/// `NSTableView` gives what's needed instead: cell reuse, a height cache, and —
/// the important one — the ability to update a single visible row's text
/// without touching the rest of the table. A streaming paragraph therefore
/// costs one text mutation per delta rather than a re-layout of the document.
struct TranscriptView: NSViewRepresentable {
    /// What the footer's ⋯ menu can do to a finished turn. Copying is handled
    /// inside the cell, which already holds the turn's rows.
    enum TurnAction {
        case fork
        case revert
    }

    var rows: [TranscriptRow]
    /// While the agent is working, skip per-move attachment hit-testing so
    /// mouseMoved events cannot starve clicks on the main thread.
    var isBusy: Bool = false
    var worktreePath: String = ""
    var persistenceKey: String
    var onRevert: (TurnID) -> Void
    var onToggleActivity: (String) -> Void
    var onOpenFile: (String) -> Void
    var onTurnAction: (TurnID, TurnAction) -> Void = { _, _ in }
    var canFork = false

    func makeCoordinator() -> Coordinator {
        Coordinator(
            persistenceKey: persistenceKey,
            worktreePath: worktreePath,
            onRevert: onRevert,
            onToggleActivity: onToggleActivity,
            onOpenFile: onOpenFile
        )
    }

    func makeNSView(context: Context) -> TranscriptContainerView {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom

        tableView.wantsLayer = true
        tableView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        let column = NSTableColumn(identifier: .init("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.usesPredominantAxisScrolling = true
        // Overlay scrollers keep the table width stable while scrolling, so
        // a scroller appearing cannot invalidate every row height mid-gesture.
        scrollView.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 12, right: 0)

        // Row heights depend on width, so a resize invalidates the cache.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.viewDidResize),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        scrollView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        // Knowing a gesture is in flight is what lets the transcript hold still
        // while the reader scrolls: bounds changes alone cannot tell the reader's
        // hand apart from the agent pinning to the bottom.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.liveScrollWillStart),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.liveScrollDidEnd),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        let container = TranscriptContainerView(scrollView: scrollView)
        // Row bitmaps (file chips, tool icons) bake in resolved colours, so a
        // light/dark switch has to invalidate and re-measure every row rather
        // than leaving dark-mode pills painted onto a light transcript.
        container.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.appearanceChanged()
        }
        context.coordinator.container = container
        container.turnRail.onSelectRow = { [weak coordinator = context.coordinator] row in
            coordinator?.scroll(to: row)
        }
        return container
    }

    func updateNSView(_ container: TranscriptContainerView, context: Context) {
        context.coordinator.onRevert = onRevert
        context.coordinator.onToggleActivity = onToggleActivity
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.onTurnAction = onTurnAction
        context.coordinator.canFork = canFork
        context.coordinator.worktreePath = worktreePath
        context.coordinator.isBusy = isBusy
        context.coordinator.update(rows: rows)
    }

    static func dismantleNSView(_ container: TranscriptContainerView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        weak var container: TranscriptContainerView?
        var onRevert: (TurnID) -> Void
        var onToggleActivity: (String) -> Void
        var onOpenFile: (String) -> Void
        var onTurnAction: (TurnID, TurnAction) -> Void = { _, _ in }
        var canFork = false
        var worktreePath: String
        var isBusy = false
        let persistenceKey: String

        private var rows: [TranscriptRow] = []
        /// Height per row id. Measuring a row means laying out its text, which
        /// is the single most expensive thing this view does, so it happens
        /// once per (row, width) rather than on every scroll tick.
        private var heightCache: [String: CGFloat] = [:]
        private var cachedWidth: CGFloat = 0
        /// The turn-rail inputs last pushed, so a streaming delta (which changes
        /// neither) doesn't force the rail to redraw and rebuild tracking areas.
        private var railTurnRows: [Int] = []
        private var railTotalRows = 0
        /// A saved scroll offset waiting to be applied. Restoring before the
        /// table has a real width (and therefore measured, correct row heights)
        /// lands the offset in the empty band above still-unmeasured rows — the
        /// blank that only fills in once a scroll forces a re-measure. So the
        /// restore is deferred until the first real layout can honour it.
        private var pendingScrollRestore: CGFloat?
        /// Coalesces UserDefaults writes so a trackpad flick isn't hundreds of
        /// preference-file hits — those stalls are what made fast scrolling feel
        /// like the table was fighting the gesture.
        private var persistScrollWork: DispatchWorkItem?
        /// Rows whose text changed but whose reload hasn't been applied yet.
        /// Streaming deltas land ~40×/second; re-rendering the growing markdown
        /// block (twice — once to measure, once to draw) at that cadence is what
        /// made scrolling stutter while an agent worked. Text-only changes are
        /// coalesced and applied at ~10 Hz instead; anything structural (a block
        /// completing, a section expanding) still applies immediately.
        private var pendingTextReload: IndexSet = []
        private var textFlushScheduled = false
        private static let textFlushInterval: TimeInterval = 0.1
        /// Whether the agent or the reader owns the scroll offset right now.
        private var policy = TranscriptScrollPolicy()
        /// Set around the table's own `scroll(to:)` calls. Bounds-change
        /// notifications post synchronously, so this reliably keeps a scroll the
        /// transcript performed from being read back as the reader scrolling away.
        private var isApplyingProgrammaticScroll = false
        /// Rows whose text changed while they were offscreen. Their heights are
        /// corrected immediately — the document must stay the right length — but
        /// the redraw waits until the view settles, since nobody can see it.
        private var deferredRedraw: IndexSet = []
        /// Momentum keeps running past `didEndLiveScroll`, so settling is judged
        /// by the offset going quiet rather than by the gesture ending.
        private var settleWork: DispatchWorkItem?
        private static let settleInterval: TimeInterval = 0.12
        /// The next chunk of the idle measuring sweep, if one is owed. Measuring
        /// the whole transcript at once — which is what this replaces — was the
        /// stall the reader felt as a scroll that could not keep up.
        private var idleMeasureWork: DispatchWorkItem?
        private static let idleMeasureChunk = 50

        init(
            persistenceKey: String,
            worktreePath: String,
            onRevert: @escaping (TurnID) -> Void,
            onToggleActivity: @escaping (String) -> Void,
            onOpenFile: @escaping (String) -> Void
        ) {
            self.persistenceKey = persistenceKey
            self.worktreePath = worktreePath
            self.onRevert = onRevert
            self.onToggleActivity = onToggleActivity
            self.onOpenFile = onOpenFile
        }

        func update(rows newRows: [TranscriptRow]) {
            guard let tableView else { return }

            let previous = rows
            rows = newRows

            // Streaming appends to the last row far more often than it adds
            // one. Reloading only what changed is what keeps a long transcript
            // responsive while text arrives.
            if previous.count == newRows.count {
                var changed: IndexSet = []
                var structural = false
                for index in newRows.indices {
                    let old = previous[index]
                    let new = newRows[index]
                    // Diff identity, not payload. Comparing `text` / `toolInput`
                    // / hashing grouped tool output was O(transcript bytes) on
                    // every flush and is what froze a long session.
                    let isStructural = old.isComplete != new.isComplete
                        || old.isQueued != new.isQueued
                        || old.isExpanded != new.isExpanded
                        || old.subagentChildCount != new.subagentChildCount
                    let contentChanged = old.contentRevision != new.contentRevision
                        || old.activitySignature != new.activitySignature
                    if contentChanged || isStructural {
                        heightCache.removeValue(forKey: new.id)
                        changed.insert(index)
                        if isStructural { structural = true }
                    }
                }
                guard !changed.isEmpty else { return }
                pendingTextReload.formUnion(changed)
                if structural {
                    flushPendingReload()
                } else {
                    scheduleTextFlush()
                }
                return
            } else if newRows.count > previous.count,
                      previous.elementsEqualByID(newRows.prefix(previous.count)) {
                // Rows appended: insert rather than reload the whole table.
                let added = IndexSet(previous.count..<newRows.count)
                tableView.insertRows(at: added, withAnimation: [])
            } else {
                pendingTextReload.removeAll()
                heightCache.removeAll()
                tableView.reloadData()
            }

            // The rail only depends on where the user messages sit and the total
            // row count — neither changes while text streams into the last row.
            // Skipping the redraw + tracking-area rebuild on every delta is what
            // keeps streaming cheap.
            let turnRows = newRows.indices.filter { newRows[$0].kind == .userMessage }
            if turnRows != railTurnRows || newRows.count != railTotalRows {
                railTurnRows = turnRows
                railTotalRows = newRows.count
                container?.turnRail.update(turnRows: turnRows, totalRows: newRows.count)
            }

            if previous.isEmpty, !newRows.isEmpty {
                let saved = UserDefaults.standard.double(forKey: persistenceKey)
                if saved > 0 {
                    pendingScrollRestore = saved
                    restorePendingScrollIfReady()
                    return
                }
            }

            // Follow the conversation only while the reader is not holding the
            // view somewhere else — and never mid-gesture, where a programmatic
            // scroll cancels their momentum instead of adding to it.
            if policy.allowsAutoScroll {
                scrollToBottom(tableView)
            }
            if previous.count != newRows.count {
                // Only the rows that just arrived, plus what surrounds the
                // viewport, need measuring now. The rest of the transcript is
                // swept in bounded chunks once nothing more urgent is happening.
                measureAroundViewport(in: tableView)
                scheduleIdleMeasurePass()
            }
        }

        func appearanceChanged() {
            guard let tableView else { return }
            pendingTextReload.removeAll()
            deferredRedraw.removeAll()
            heightCache.removeAll()
            measureAroundViewport(in: tableView)
            scheduleIdleMeasurePass()
            tableView.reloadData()
        }

        /// Applies the accumulated text-only row reloads in one pass: height
        /// note + reload + bottom pin, exactly what used to happen per delta,
        /// now at most every `textFlushInterval`.
        private func flushPendingReload() {
            guard let tableView else { return }
            let indexes = pendingTextReload.filteredIndexSet { rows.indices.contains($0) }
            pendingTextReload.removeAll()
            guard !indexes.isEmpty else { return }
            let visible = visibleRowRange(in: tableView)
            let apply = {
                // The growing last row must not animate its height change. The
                // default row-height animation reflows the paragraph the reader
                // is mid-way through on every streaming delta, which is the
                // "bouncing" that makes the final response hard to read. A
                // zero-duration context applies the new height in place instead.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    tableView.noteHeightOfRows(withIndexesChanged: indexes)
                }
                // Re-drawing a row nobody is looking at is the bulk of the work
                // a streaming turn asks for once the reader has scrolled up —
                // the agent writes at the foot of a transcript they left behind.
                // Its height is already corrected above, so holding the draw
                // until the view settles changes nothing they can see.
                let onscreen = indexes.filteredIndexSet { visible.contains($0) }
                if self.policy.deferOffscreenRedraws {
                    self.deferredRedraw.formUnion(indexes.subtracting(onscreen))
                }
                let redraw = self.policy.deferOffscreenRedraws ? onscreen : indexes
                if !redraw.isEmpty {
                    tableView.reloadData(
                        forRowIndexes: redraw,
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }

            if policy.allowsAutoScroll {
                apply()
                scrollToBottom(tableView)
            } else {
                // Not following: the reader is reading something further up, and
                // a row growing below — or above — must not slide it.
                preservingVisualAnchor(apply)
            }
        }

        private func scheduleTextFlush() {
            guard !textFlushScheduled else { return }
            textFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.textFlushInterval) { [weak self] in
                guard let self else { return }
                self.textFlushScheduled = false
                self.flushPendingReload()
            }
        }

        /// Applies a deferred scroll restore once the table can honour it — i.e.
        /// it has a real width, so every row height is measured and the document
        /// is its true height. Called again from `viewDidResize` for the case
        /// where the first `update` ran before the view had been sized.
        private func restorePendingScrollIfReady() {
            guard let target = pendingScrollRestore,
                  let tableView,
                  let scrollView = tableView.enclosingScrollView,
                  tableView.bounds.width > 1 else { return }
            // Force the measure now so the offset lands on real content, not the
            // blank band above rows the table hasn't laid out yet.
            tableView.layoutSubtreeIfNeeded()
            withProgrammaticScroll {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            pendingScrollRestore = nil
            // Reopening a chat part-way up means the reader left it there; the
            // agent should not haul them back down to resume it.
            policy.didJump(toBottom: isScrolledToBottom(tableView))
        }

        @objc func viewDidResize(_ notification: Notification) {
            guard let tableView else { return }
            let width = tableView.bounds.width
            guard abs(width - cachedWidth) > 1 else { return }
            cachedWidth = width
            heightCache.removeAll()
            measureAroundViewport(in: tableView)
            scheduleIdleMeasurePass()
            // A width was just established; a restore that couldn't run on load
            // (view not yet sized) can finally land correctly.
            restorePendingScrollIfReady()
        }

        @objc func liveScrollWillStart(_ notification: Notification) {
            policy.userDidBeginScroll()
            settleWork?.cancel()
        }

        @objc func liveScrollDidEnd(_ notification: Notification) {
            // The fingers have left the trackpad but the momentum has not; the
            // offset going quiet is what actually marks the end of the gesture.
            scheduleSettle()
        }

        @objc func scrollDidChange(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView else { return }
            let y = clip.bounds.origin.y
            persistScrollWork?.cancel()
            let work = DispatchWorkItem { [persistenceKey] in
                UserDefaults.standard.set(y, forKey: persistenceKey)
            }
            persistScrollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)

            // Anything that moved the offset and wasn't the transcript itself was
            // the reader — a gesture, its momentum, or a keyboard scroll, which
            // posts no live-scroll notification at all.
            if !isApplyingProgrammaticScroll, let tableView {
                policy.userDidScroll(atBottom: isScrolledToBottom(tableView))
                scheduleSettle()
            }
            updateActiveTurn()
        }

        /// Marks the view settled once the offset has been quiet for a moment,
        /// then pays back the work held off during the gesture.
        private func scheduleSettle() {
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let tableView = self.tableView else { return }
                self.policy.userDidEndScroll(atBottom: self.isScrolledToBottom(tableView))
                let deferred = self.deferredRedraw.filteredIndexSet { self.rows.indices.contains($0) }
                self.deferredRedraw.removeAll()
                if !deferred.isEmpty {
                    tableView.reloadData(
                        forRowIndexes: deferred,
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
                self.measureAroundViewport(in: tableView)
                self.scheduleIdleMeasurePass()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleInterval, execute: work)
        }

        // MARK: - Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 20 }
            let item = rows[row]
            if let cached = heightCache[item.id] { return cached }

            let available = tableView.bounds.width - TranscriptCell.horizontalInset * 2
            // Before the table has a real width (the first layout pass reports 0),
            // measuring would wrap every row's text at a bogus 100pt and cache a
            // wildly-too-tall height. That inflated the document, so restoring the
            // scroll position landed in empty space above the content — the blank
            // band that only filled in once a scroll forced a re-measure. Hand back
            // a provisional height *without* caching until the width is real.
            guard available > 1 else { return TranscriptCell.estimatedHeight(for: item) }

            let width = min(max(available, 100), TranscriptCell.contentMaxWidth)
            let height = TranscriptCell.height(for: item, width: width, worktreePath: worktreePath)
            heightCache[item.id] = height
            return height
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self)
                as? TranscriptCell ?? TranscriptCell(identifier: identifier)
            cell.configure(
                with: rows[row],
                worktreePath: worktreePath,
                canFork: canFork,
                skipHoverTracking: isBusy,
                onRevert: onRevert,
                onToggleActivity: onToggleActivity,
                onOpenFile: onOpenFile,
                onTurnAction: onTurnAction
            )
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        /// The rows the reader can see, plus a small margin so a row entering the
        /// viewport is already measured rather than measured on arrival.
        private func visibleRowRange(in tableView: NSTableView) -> Range<Int> {
            let visible = tableView.rows(in: tableView.visibleRect)
            // `rows(in:)` reports NSNotFound when the rect holds no rows; letting
            // that flow into the range math would make `start` exceed `end`.
            guard visible.location != NSNotFound else { return 0..<0 }
            let start = max(0, visible.location - 4)
            let end = min(rows.count, visible.location + max(visible.length, 1) + 4)
            guard start < end else { return 0..<0 }
            return start..<end
        }

        /// Measures `indices`, invalidating only the rows whose height actually
        /// moved.
        ///
        /// This filter is the point. `noteHeightOfRows` makes the table re-derive
        /// every row origin below the ones it is given, so invalidating a row that
        /// already has the right height costs a full re-layout for a result
        /// identical to what was on screen. Most rows in a transcript never change
        /// height at all, so measuring first and noting second turns what used to
        /// be a whole-document reflow into, usually, nothing.
        @discardableResult
        private func measure(_ indices: some Sequence<Int>, in tableView: NSTableView) -> IndexSet {
            var changed = IndexSet()
            for index in indices where rows.indices.contains(index) {
                let current = tableView.rect(ofRow: index).height
                let measured = self.tableView(tableView, heightOfRow: index)
                if abs(current - measured) > 0.5 { changed.insert(index) }
            }
            guard !changed.isEmpty else { return changed }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                tableView.noteHeightOfRows(withIndexesChanged: changed)
            }
            return changed
        }

        /// Measures around the viewport, keeping whatever the reader is looking at
        /// visually still if the correction lands above them.
        private func measureAroundViewport(in tableView: NSTableView) {
            guard tableView.bounds.width > 1, !rows.isEmpty else { return }
            let window = visibleRowRange(in: tableView)
            let start = max(0, window.lowerBound - 20)
            let end = min(rows.count, max(window.upperBound + 30, start + 1))
            guard start < end else { return }
            if policy.allowsAutoScroll {
                measure(start..<end, in: tableView)
            } else {
                preservingVisualAnchor { self.measure(start..<end, in: tableView) }
            }
        }

        /// Sweeps the rest of the transcript in bounded chunks on idle turns of
        /// the run loop.
        ///
        /// NSTableView asks for a height only as a row nears the viewport, so an
        /// unmeasured row is the blank card at the edge of a fast flick. The fix
        /// for that used to be measuring *every* row and invalidating *every*
        /// row's height — on every appended row, which while an agent works is
        /// constant. That reflowed the whole document tens of times a turn, and it
        /// is what made scrolling during a live turn feel like wading. Chunking
        /// bounds each turn's cost, yielding while a gesture is in flight keeps the
        /// gesture smooth, and the measured-height filter means the sweep usually
        /// invalidates nothing at all.
        private func scheduleIdleMeasurePass() {
            guard idleMeasureWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.idleMeasureWork = nil
                self.runIdleMeasureChunk()
            }
            idleMeasureWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        private func runIdleMeasureChunk() {
            guard let tableView, tableView.bounds.width > 1, !rows.isEmpty else { return }
            // A gesture in flight outranks speculative work; try again once it
            // settles rather than measuring underneath it.
            guard policy.allowsBackgroundMeasuring else { scheduleIdleMeasurePass(); return }

            // The unmeasured rows themselves, not the span they sit in: gaps
            // between them are already measured, and sweeping across those would
            // put the bound back on the span rather than on the work.
            var chunk: [Int] = []
            var pending = false
            for index in rows.indices where heightCache[rows[index].id] == nil {
                if chunk.count >= Self.idleMeasureChunk { pending = true; break }
                chunk.append(index)
            }
            guard !chunk.isEmpty else { return }
            if policy.allowsAutoScroll {
                measure(chunk, in: tableView)
            } else {
                preservingVisualAnchor { self.measure(chunk, in: tableView) }
            }
            if pending { scheduleIdleMeasurePass() }
        }

        /// Applies a layout change while keeping the row the reader is looking at
        /// visually still.
        ///
        /// A table preserves its *document* offset across a height change, not the
        /// reader's place in it: correct a row above the viewport and everything
        /// they are reading slides by that much. During a live turn those
        /// corrections arrive continuously, which is the drift that makes scrolling
        /// back through a working agent feel unsteady. Re-pinning the topmost
        /// visible row to the same screen position turns the correction invisible.
        private func preservingVisualAnchor(_ body: () -> Void) {
            guard let tableView,
                  let scrollView = tableView.enclosingScrollView,
                  case let visible = tableView.rows(in: tableView.visibleRect),
                  visible.location != NSNotFound, visible.length > 0
            else { body(); return }

            let clip = scrollView.contentView
            let anchor = visible.location
            let before = tableView.rect(ofRow: anchor).minY - clip.bounds.origin.y
            body()
            tableView.layoutSubtreeIfNeeded()
            let after = tableView.rect(ofRow: anchor).minY - clip.bounds.origin.y
            let drift = after - before
            guard abs(drift) > 0.5 else { return }
            withProgrammaticScroll {
                clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y + drift)))
                scrollView.reflectScrolledClipView(clip)
            }
        }

        // MARK: - Scrolling

        /// Marks a scroll as the transcript's own, so the bounds-change it causes
        /// is not read back as the reader scrolling away — which would switch
        /// following off the instant the agent pinned to the bottom. Bounds
        /// notifications post synchronously, so the flag can be cleared here.
        private func withProgrammaticScroll(_ body: () -> Void) {
            let wasApplying = isApplyingProgrammaticScroll
            isApplyingProgrammaticScroll = true
            body()
            isApplyingProgrammaticScroll = wasApplying
        }

        private func isScrolledToBottom(_ tableView: NSTableView) -> Bool {
            guard let scrollView = tableView.enclosingScrollView else { return true }
            let visible = scrollView.contentView.documentVisibleRect
            let contentHeight = tableView.bounds.height
            // A small slack, so "close enough to the bottom" still follows.
            return visible.maxY >= contentHeight - 40
        }

        private func scrollToBottom(_ tableView: NSTableView) {
            guard !rows.isEmpty, let scrollView = tableView.enclosingScrollView else { return }
            // Pin the document's bottom edge rather than `scrollRowToVisible`.
            // Once the streaming row grows taller than the viewport,
            // `scrollRowToVisible` aligns the row's *top*, so newest text keeps
            // jumping out of view; pinning the bottom keeps the latest line
            // steady at the foot of the transcript. `rect(ofRow:)` reads the
            // height cache after `noteHeightOfRows` — laying out the whole
            // subtree on every flush was a stall of its own.
            let lastRect = tableView.rect(ofRow: rows.count - 1)
            let contentHeight = lastRect == .zero ? tableView.bounds.height : lastRect.maxY
            let clip = scrollView.contentView
            let targetY = max(0, contentHeight - clip.bounds.height)
            // Already there: scrolling anyway would still post a bounds change and
            // cancel any momentum the reader has in flight, for no movement.
            guard abs(clip.bounds.origin.y - targetY) > 0.5 else { return }
            withProgrammaticScroll {
                clip.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clip)
            }
        }

        func scroll(to row: Int) {
            guard let tableView, rows.indices.contains(row) else { return }
            withProgrammaticScroll { tableView.scrollRowToVisible(row) }
            // Jumping to an earlier turn is a request to read there, so the agent
            // stops pulling the view back down until the reader returns to the foot.
            policy.didJump(toBottom: isScrolledToBottom(tableView))
        }

        private func updateActiveTurn() {
            guard let tableView, let rail = container?.turnRail else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            let middle = visible.location + max(visible.length / 2, 0)
            rail.activeRow = Self.nearest(to: middle, in: rail.turnRows)
        }

        /// Closest value in an ascending array, in O(log n). The rail resolves
        /// this on every scroll tick; a linear scan over every user message was
        /// work a fast scroll could feel in a long conversation.
        private static func nearest(to target: Int, in sorted: [Int]) -> Int? {
            guard !sorted.isEmpty else { return nil }
            var low = 0
            var high = sorted.count - 1
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid] < target { low = mid + 1 } else { high = mid }
            }
            // `low` is the first element >= target; its predecessor may be nearer.
            if low > 0, abs(sorted[low - 1] - target) <= abs(sorted[low] - target) {
                return sorted[low - 1]
            }
            return sorted[low]
        }
    }
}

/// Hosts the virtualized transcript and a compact turn minimap. Each marker is
/// one user prompt, making long conversations directly navigable without
/// replacing the native scrollbar or stealing its gestures.
final class TranscriptContainerView: NSView {
    let scrollView: NSScrollView
    let turnRail = TurnRailView()
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        turnRail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(turnRail)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            turnRail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            turnRail.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            turnRail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -50),
            turnRail.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

final class TurnRailView: NSView {
    var turnRows: [Int] = []
    var totalRows = 0
    // Only a genuine change is worth a redraw; the scroll observer sets this on
    // every tick, and most ticks leave the active turn exactly where it was.
    var activeRow: Int? { didSet { if oldValue != activeRow { needsDisplay = true } } }
    var onSelectRow: ((Int) -> Void)?
    private var isHovering = false

    override var isFlipped: Bool { true }

    func update(turnRows: [Int], totalRows: Int) {
        self.turnRows = turnRows
        self.totalRows = totalRows
        if activeRow == nil { activeRow = turnRows.last }
        needsDisplay = true
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let nearest = turnRows.min(by: {
            abs(y(for: $0) - point.y) < abs(y(for: $1) - point.y)
        }) else { return }
        activeRow = nearest
        onSelectRow?(nearest)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !turnRows.isEmpty else { return }
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 2, y: 4, width: 1, height: max(0, bounds.height - 8)), xRadius: 0.5, yRadius: 0.5).fill()
        for row in turnRows {
            let active = row == activeRow
            let width: CGFloat = active ? 13 : (isHovering ? 8 : 5)
            let rect = NSRect(x: bounds.maxX - width, y: y(for: row) - 2, width: width, height: 4)
            (active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.5)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func y(for row: Int) -> CGFloat {
        let usable = max(0, bounds.height - 16)
        let fraction = totalRows <= 1 ? 0 : CGFloat(row) / CGFloat(totalRows - 1)
        return 8 + usable * fraction
    }
}

private extension Array where Element == TranscriptRow {
    func elementsEqualByID(_ other: ArraySlice<TranscriptRow>) -> Bool {
        guard count == other.count else { return false }
        for (mine, theirs) in zip(self, other) where mine.id != theirs.id { return false }
        return true
    }
}

/// Lays out transcript text the same way the cell's `NSTextView` does, so a
/// row's table height matches what is actually drawn. `NSAttributedString.boundingRect`
/// disagrees with TextKit once code-block `NSTextTable`s or attachment chips
/// are involved, and that disagreement is the empty gap under a finished reply.
@MainActor
enum TranscriptHeightMeasurer {
    private static let textView: NSTextView = {
        let view = NSTextView(frame: .zero)
        view.isRichText = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineBreakMode = .byWordWrapping
        return view
    }()

    static func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 1, string.length > 0 else { return 0 }
        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return ceil(string.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            ).height)
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(string)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }
}

/// One transcript row, drawn with TextKit.
final class TranscriptCell: NSTableCellView {
    static let horizontalInset: CGFloat = 24
    static let contentMaxWidth: CGFloat = OreTheme.contentMaxWidth
    private static let verticalInset: CGFloat = 8

    /// Rows produced inside a subagent are indented under it; this is the
    /// vertical guide drawn at the indent, mirroring a nested thread.
    static let subagentIndent: CGFloat = 22

    private let bubble = NSView()
    private let indentGuide = NSView()
    private let label = TranscriptTextView(frame: .zero)
    private let badge = NSTextField(labelWithString: "")
    private let contentGuide = NSLayoutGuide()
    private var badgeHeightZero: NSLayoutConstraint!
    private var labelTrailingConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var bubbleTopConstraint: NSLayoutConstraint!
    private var bubbleBottomConstraint: NSLayoutConstraint!
    private var preferredWidthConstraint: NSLayoutConstraint!
    private var userWidthConstraint: NSLayoutConstraint!
    private var revertAction: (() -> Void)?
    private var toggleActivityAction: (() -> Void)?
    private let copyButton = NSButton()
    private let menuButton = NSButton()
    private var copyableText = ""
    private var isUserMessage = false
    private var copyTrackingArea: NSTrackingArea?
    /// The turn a footer row's ⋯ menu acts on, and what it may offer.
    private var footerTurnID: TurnID?
    private var footerResponse = ""
    private var footerCanFork = false
    private var onTurnAction: ((TurnID, TranscriptView.TurnAction) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = OreTheme.controlRadius
        bubble.layer?.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        // A copy affordance for user messages, revealed on hover in the gutter
        // beside the bubble so it never overlaps the text.
        copyButton.isBordered = false
        copyButton.bezelStyle = .regularSquare
        copyButton.imagePosition = .imageOnly
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy message")
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyMessage)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isHidden = true
        copyButton.toolTip = "Copy message"
        addSubview(copyButton)

        // The turn footer's overflow menu. A real button rather than a glyph in
        // the attributed string, because the row's text view swallows clicks to
        // drive expand/collapse.
        menuButton.isBordered = false
        menuButton.bezelStyle = .regularSquare
        menuButton.imagePosition = .imageOnly
        menuButton.image = NSImage(
            systemSymbolName: "ellipsis", accessibilityDescription: "Turn actions"
        )
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.target = self
        menuButton.action = #selector(showTurnMenu)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.isHidden = true
        menuButton.toolTip = "Actions for this turn"
        addSubview(menuButton)
        addLayoutGuide(contentGuide)

        indentGuide.wantsLayer = true
        indentGuide.layer?.cornerRadius = 1
        indentGuide.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indentGuide)

        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(badge)

        // An NSTextView, not a wrapping NSTextField. A selectable label routes
        // selection through the window's shared field editor, which redraws the
        // text in the field's own font and colour — that is the "formatting
        // changes when I click it" bug. A read-only text view draws the
        // attributed string directly, so selecting it never restyles it.
        label.drawsBackground = false
        label.delegate = label
        label.isEditable = false
        label.isSelectable = true
        // File chips carry their own pill styling, so links must not add the
        // default blue underline on top. Keep only the pointing-hand cursor.
        label.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        label.isVerticallyResizable = false
        label.isHorizontallyResizable = false
        label.textContainerInset = .zero
        label.textContainer?.lineFragmentPadding = 0
        label.textContainer?.widthTracksTextView = true
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)

        badgeHeightZero = badge.heightAnchor.constraint(equalToConstant: 0)
        labelTrailingConstraint = label.trailingAnchor.constraint(
            equalTo: bubble.trailingAnchor, constant: -10
        )

        // A left-aligned content column, not a centred bubble. A short "hi" used
        // to float as a tiny island in the middle of the pane; rows now begin at
        // the leading edge and grow to the content max width. The width prefers
        // 680 but yields to the trailing edge on a narrow window.
        preferredWidthConstraint = bubble.widthAnchor.constraint(equalTo: contentGuide.widthAnchor)
        preferredWidthConstraint.priority = .defaultHigh
        leadingConstraint = bubble.leadingAnchor.constraint(
            equalTo: contentGuide.leadingAnchor
        )
        trailingConstraint = bubble.trailingAnchor.constraint(
            equalTo: contentGuide.trailingAnchor
        )
        userWidthConstraint = bubble.widthAnchor.constraint(equalToConstant: 620)
        userWidthConstraint.priority = .defaultHigh

        // Held as properties so the vertical inset can tighten per row — process
        // rows (tool calls, thinking, activity) sit closer together than prose.
        bubbleTopConstraint = bubble.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset)
        bubbleBottomConstraint = bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset)

        NSLayoutConstraint.activate([
            contentGuide.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentGuide.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.horizontalInset),
            contentGuide.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalInset),
            contentGuide.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentMaxWidth),
            {
                let constraint = contentGuide.widthAnchor.constraint(equalToConstant: Self.contentMaxWidth)
                constraint.priority = .defaultHigh
                return constraint
            }(),
            leadingConstraint,
            bubble.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentGuide.leadingAnchor
            ),
            bubble.trailingAnchor.constraint(
                lessThanOrEqualTo: contentGuide.trailingAnchor
            ),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentMaxWidth),
            preferredWidthConstraint,
            bubbleTopConstraint,
            bubbleBottomConstraint,

            badge.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 6),

            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            labelTrailingConstraint,
            label.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),

            indentGuide.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: 8),
            indentGuide.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 3),
            indentGuide.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -3),
            indentGuide.widthAnchor.constraint(equalToConstant: 2),

            copyButton.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -8),
            copyButton.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 2),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),

            menuButton.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -4),
            menuButton.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 2),
            menuButton.widthAnchor.constraint(equalToConstant: 24),
            menuButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(
        with row: TranscriptRow,
        worktreePath: String = "",
        canFork: Bool = false,
        skipHoverTracking: Bool = false,
        onRevert: @escaping (TurnID) -> Void,
        onToggleActivity: @escaping (String) -> Void,
        onOpenFile: @escaping (String) -> Void,
        onTurnAction: @escaping (TurnID, TranscriptView.TurnAction) -> Void = { _, _ in }
    ) {
        let isFooter = row.kind == .turnFooter
        menuButton.isHidden = !isFooter
        // Keep the footer's file chips clear of the ⋯ button they'd otherwise
        // wrap underneath. `Self.trailingInset` mirrors this in `height(for:)`
        // so the measured height matches what is drawn.
        labelTrailingConstraint.constant = -Self.trailingInset(for: row)
        footerTurnID = isFooter ? row.turnID : nil
        footerCanFork = canFork
        footerResponse = isFooter ? Self.finalResponse(in: row.groupedRows) : ""
        self.onTurnAction = onTurnAction

        let badgeString = Self.badgeText(for: row)
        badge.stringValue = badgeString
        badge.isHidden = badgeString.isEmpty
        badgeHeightZero.isActive = badgeString.isEmpty

        let isUser = row.kind == .userMessage
        copyableText = Self.copyableText(for: row)
        isUserMessage = isUser
        // The copy button belongs to user messages; it stays hidden until the
        // row is hovered (see mouseEntered/Exited).
        if !isUser { copyButton.isHidden = true }
        let inset = Self.verticalInset(for: row)
        bubbleTopConstraint.constant = inset
        bubbleBottomConstraint.constant = -inset

        let indent = row.parentToolCallID != nil ? Self.subagentIndent : 0
        leadingConstraint.constant = indent
        indentGuide.isHidden = indent == 0
        leadingConstraint.isActive = !isUser
        trailingConstraint.isActive = isUser
        preferredWidthConstraint.isActive = !isUser
        userWidthConstraint.isActive = isUser

        if isUser {
            let natural = Self.attributedText(for: row, worktreePath: worktreePath).boundingRect(
                with: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width + 20
            userWidthConstraint.constant = min(max(120, ceil(natural)), 620)
        }

        let attributedText = Self.attributedText(for: row, worktreePath: worktreePath)
        label.dismissAttachmentPreview()
        label.textStorage?.setAttributedString(attributedText)
        label.onOpenFile = onOpenFile
        label.skipHoverTracking = skipHoverTracking
        // Activity groups toggle on a click, so their text isn't selectable;
        // every other row is, now that selecting no longer restyles it. The
        // gestures the cell used to own are routed through the text view too,
        // so they still fire when the click lands on the text rather than the
        // surrounding padding.
        let isProcess = row.kind == .activityGroup || row.kind == .toolCall
            || row.kind == .thinking || row.kind == .error
        var hasLink = false
        if attributedText.length > 0 {
            attributedText.enumerateAttribute(
                .link,
                in: NSRange(location: 0, length: attributedText.length)
            ) { value, _, stop in
                if value != nil { hasLink = true; stop.pointee = true }
            }
        }
        label.isSelectable = !isProcess || hasLink
        label.onSingleClick = isProcess ? { onToggleActivity(row.id) } : nil
        label.onDoubleClick = row.kind == .userMessage ? { onRevert(row.turnID) } : nil

        // `cgColor` snapshots a dynamic colour against the appearance current
        // at this instant, so every layer colour is re-resolved on each
        // configure rather than set once in `init` — the transcript reloads on
        // an appearance change precisely so this runs again.
        bubble.layer?.backgroundColor = Self.background(for: row).cgColor
        bubble.layer?.borderWidth = 0
        bubble.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        indentGuide.layer?.backgroundColor = NSColor.separatorColor
            .withAlphaComponent(0.6).cgColor
        // Double-click reverts, but only on a user message — the gesture means
        // "go back to what I asked here". On any other row, and especially on
        // the new footer, it would be an unexplained destructive action.
        revertAction = isUser ? { onRevert(row.turnID) } : nil
        toggleActivityAction = isProcess
            ? { onToggleActivity(row.id) }
            : nil

        if row.kind == .userMessage {
            toolTip = "Revert the workspace to before this message"
        } else if isProcess {
            toolTip = row.isExpanded ? "Collapse activity" : "Expand activity"
        } else {
            toolTip = nil
        }
    }

    /// A double-click on a user message reverts to it — the same gesture as
    /// "go back to here" in the transcript.
    override func mouseDown(with event: NSEvent) {
        if let toggleActivityAction {
            toggleActivityAction()
            return
        }
        guard event.clickCount == 2, let revertAction else {
            super.mouseDown(with: event)
            return
        }
        revertAction()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let copyTrackingArea { removeTrackingArea(copyTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        copyTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if isUserMessage { copyButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        copyButton.isHidden = true
    }

    @objc private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableText, forType: .string)
    }

    @objc private func showTurnMenu() {
        guard footerTurnID != nil else { return }
        let menu = NSMenu()

        if !footerResponse.isEmpty {
            let copy = NSMenuItem(
                title: "Copy Response", action: #selector(copyFooterResponse), keyEquivalent: ""
            )
            copy.target = self
            menu.addItem(copy)
        }
        // Offered only where the harness can actually branch a session. A menu
        // entry that silently starts an unrelated chat would be worse than not
        // offering the action at all.
        if footerCanFork {
            let fork = NSMenuItem(
                title: "Fork to New Tab", action: #selector(forkTurn), keyEquivalent: ""
            )
            fork.target = self
            fork.toolTip = "Continue this conversation in a new tab, leaving this one intact"
            menu.addItem(fork)
        }
        menu.addItem(.separator())
        let revert = NSMenuItem(
            title: "Revert to Before This Turn", action: #selector(revertTurn), keyEquivalent: ""
        )
        revert.target = self
        menu.addItem(revert)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: menuButton.bounds.height),
            in: menuButton
        )
    }

    @objc private func copyFooterResponse() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(footerResponse, forType: .string)
    }

    @objc private func forkTurn() {
        guard let footerTurnID else { return }
        onTurnAction?(footerTurnID, .fork)
    }

    @objc private func revertTurn() {
        guard let footerTurnID else { return }
        onTurnAction?(footerTurnID, .revert)
    }

    /// The block the turn ended on — the answer, as opposed to the preamble
    /// that led up to it.
    private static func finalResponse(in rows: [TranscriptRow]) -> String {
        rows.last {
            $0.kind == .assistantText
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text ?? ""
    }

    /// Right-click a user message to copy it, in addition to the hover button.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isUserMessage else { return super.menu(for: event) }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Message", action: #selector(copyMessage), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    // MARK: - Presentation

    /// Space kept free at the bubble's trailing edge. Only the turn footer
    /// needs it, for its ⋯ button.
    static func trailingInset(for row: TranscriptRow) -> CGFloat {
        row.kind == .turnFooter ? 34 : 10
    }

    static func height(for row: TranscriptRow, width: CGFloat, worktreePath: String = "") -> CGFloat {
        if row.kind == .divider { return 36 }
        let attributed = attributedText(for: row, worktreePath: worktreePath)
        let indent = row.parentToolCallID != nil ? subagentIndent : 0
        let bubbleWidth = row.kind == .userMessage ? min(width * 0.72, 620) : width - indent
        let textWidth = max(1, bubbleWidth - 10 - trailingInset(for: row))
        // TextKit, not `boundingRect`. Markdown with `NSTextTable` code blocks
        // (and attachment chips) makes boundingRect invent a height far taller
        // than the text view actually draws — the empty gap between a reply and
        // its footer. Measuring through the same layout manager the cell uses
        // keeps those two numbers identical.
        let textHeight = TranscriptHeightMeasurer.height(of: attributed, width: textWidth)
        let badgeLine: CGFloat = badgeText(for: row).isEmpty ? 0 : 14
        return ceil(textHeight) + 16 + verticalInset(for: row) * 2 + badgeLine
    }

    /// Placeholder used only before the table has a real width. Kind-specific
    /// so an unmeasured assistant reply doesn't collapse to a 20pt stub (the
    /// blank strip at the edge of a fast scroll).
    static func estimatedHeight(for row: TranscriptRow) -> CGFloat {
        switch row.kind {
        case .assistantText, .plan: return 72
        case .userMessage: return 44
        case .turnFooter: return 28
        case .divider: return 36
        case .toolCall, .thinking, .activityGroup, .error: return 28
        }
    }

    /// Process rows — tool calls, thinking, the collapsed activity group — sit
    /// closer together than prose so a run of them reads as one quiet block
    /// rather than a widely-spaced list competing with the answer.
    private static func verticalInset(for row: TranscriptRow) -> CGFloat {
        switch row.kind {
        case .toolCall, .thinking, .activityGroup, .error: return 4
        case .turnFooter: return 4
        default: return verticalInset
        }
    }

    /// The row's rendered content.
    ///
    /// Agent prose is markdown — headings, lists, inline code, fenced blocks —
    /// and showing it raw makes the reader parse formatting by eye in the one
    /// place they are trying to read quickly. Measuring and drawing both go
    /// through here so a row's cached height always matches what it draws.
    static func attributedText(for row: TranscriptRow, worktreePath: String = "") -> NSAttributedString {
        let appearance = currentAppearance.name.rawValue
        if let cached = renderCache.value(for: row, appearance: appearance) { return cached }

        let rendered: NSAttributedString
        switch row.kind {
        case .assistantText, .plan:
            // swift-markdown accepts incomplete CommonMark, so the answer can
            // grow as a structured document: headings, lists, and fenced code
            // settle progressively instead of flashing from raw source to rich
            // text only when the entire block completes.
            rendered = MarkdownRenderer(
                baseFont: font(for: row),
                textColor: textColor(for: row),
                highlighter: SyntaxHighlighter.shared
            ).render(row.text, highlighting: row.isComplete ? .all : .stablePrefix)

        case .toolCall, .thinking, .error:
            rendered = processText(for: row, worktreePath: worktreePath)

        case .activityGroup:
            rendered = activityGroupText(for: row)

        case .turnFooter:
            rendered = turnFooterText(for: row)

        case .userMessage:
            rendered = userMessageText(for: row, worktreePath: worktreePath)

        case .divider:
            rendered = NSAttributedString(
                string: displayText(for: row),
                attributes: [.font: font(for: row), .foregroundColor: textColor(for: row)]
            )
        }

        renderCache.store(rendered, for: row, appearance: appearance)
        return rendered
    }

    /// Markdown parsing is not free, and a streaming row is re-measured and
    /// redrawn on every delta. Caching by (id, text length, completeness) keeps
    /// that to one parse per change rather than several.
    private nonisolated(unsafe) static var renderCache = RenderCache()

    struct RenderCache {
        private var entries: [String: (signature: Int, value: NSAttributedString)] = [:]

        /// Rendered rows bake in resolved colours and rasterised chips, so the
        /// appearance is part of a row's identity — a light/dark switch has to
        /// invalidate every entry. It is passed in rather than read here
        /// because the cache itself is not main-actor isolated.
        private func signature(for row: TranscriptRow, appearance: String) -> Int {
            var hasher = Hasher()
            hasher.combine(appearance)
            hasher.combine(row.contentRevision)
            hasher.combine(row.activitySignature)
            hasher.combine(row.text)
            hasher.combine(row.resultText)
            hasher.combine(row.isComplete)
            hasher.combine(row.isQueued)
            hasher.combine(row.isExpanded)
            hasher.combine(row.toolInput)
            hasher.combine(row.resultMetadata)
            hasher.combine(row.resolvedSubject)
            hasher.combine(row.attachments)
            hasher.combine(row.subagentChildCount)
            return hasher.finalize()
        }

        func value(for row: TranscriptRow, appearance: String) -> NSAttributedString? {
            guard let entry = entries[row.id],
                  entry.signature == signature(for: row, appearance: appearance)
            else { return nil }
            return entry.value
        }

        mutating func store(
            _ value: NSAttributedString,
            for row: TranscriptRow,
            appearance: String
        ) {
            if entries.count >= Self.capacity { evictOldest() }
            recency[row.id] = tick
            tick += 1
            entries[row.id] = (signature(for: row, appearance: appearance), value)
        }

        private static let capacity = 2_000
        private var recency: [String: UInt64] = [:]
        private var tick: UInt64 = 0

        /// Drops the least recently rendered half.
        ///
        /// Clearing the whole cache at the cap meant a transcript longer than
        /// the cap re-parsed every visible row on the next scroll tick, over and
        /// over. Evicting the cold half keeps the rows the reader is actually
        /// looking at warm.
        private mutating func evictOldest() {
            let survivors = recency.sorted { $0.value > $1.value }
                .prefix(Self.capacity / 2)
                .map(\.key)
            let keep = Set(survivors)
            entries = entries.filter { keep.contains($0.key) }
            recency = recency.filter { keep.contains($0.key) }
        }
    }

    private static func displayText(for row: TranscriptRow) -> String {
        switch row.kind {
        case .divider:
            return "—  \(row.text)  —"
        case .toolCall:
            return processPresentation(for: row).title
        case .activityGroup:
            return "\(row.isExpanded ? "⌄" : "›") \(row.text)"
        default:
            return row.text
        }
    }

    static func copyableText(for row: TranscriptRow) -> String {
        guard !row.attachments.isEmpty else { return row.text }
        let names = row.attachments.map { "@\($0.displayName)" }.joined(separator: "  ")
        if row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return names }
        return row.text + "\n\n" + names
    }

    /// User bubbles keep the typed prose, then chips for attachments that were
    /// not already written as `@name` tokens. Images and long pasted text are
    /// chips (or styled tokens) with a hover preview — the same treatment as
    /// the composer — rather than a tiny thumbnail or a wall of pasted prose.
    private static func userMessageText(
        for row: TranscriptRow,
        worktreePath: String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: row),
            .foregroundColor: textColor(for: row),
        ]
        if !row.text.isEmpty {
            result.append(styledMentions(
                row.text,
                attachments: row.attachments,
                worktreePath: worktreePath,
                attributes: attributes
            ))
        }

        let mentioned = Set(
            row.attachments
                .filter { row.text.contains("@\($0.displayName)") }
                .map(\.relativePath)
        )
        let extras = row.attachments.filter { !mentioned.contains($0.relativePath) }
        let images = extras.filter(\.isImage)
        let files = extras.filter { !$0.isImage }
        if !images.isEmpty || !files.isEmpty {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            for (index, attachment) in images.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: "  ", attributes: attributes)) }
                appendChip(for: attachment, worktreePath: worktreePath, to: result)
            }
            if !images.isEmpty, !files.isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            for (index, attachment) in files.enumerated() {
                if index > 0 { result.append(NSAttributedString(string: " ", attributes: attributes)) }
                appendChip(for: attachment, worktreePath: worktreePath, to: result)
            }
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: " ", attributes: attributes))
        }
        return result
    }

    private static func styledMentions(
        _ text: String,
        attachments: [Attachment],
        worktreePath: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let named = attachments.filter { !$0.displayName.isEmpty }
        guard !named.isEmpty else { return result }
        let source = result.string as NSString
        for attachment in named {
            let token = "@\(attachment.displayName)"
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let found = source.range(of: token, options: [], range: search)
                guard found.location != NSNotFound else { break }
                var tokenAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                    .foregroundColor: NSColor.controlAccentColor,
                    .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10),
                ]
                if attachment.isHoverPreviewable {
                    tokenAttributes[.oreAttachmentPreview] = attachment.fileURL(worktreePath: worktreePath)
                    tokenAttributes[.cursor] = NSCursor.pointingHand
                }
                result.addAttributes(tokenAttributes, range: found)
                let next = NSMaxRange(found)
                search = NSRange(location: next, length: source.length - next)
            }
        }
        return result
    }

    private static func appendChip(
        for attachment: Attachment,
        worktreePath: String,
        to result: NSMutableAttributedString
    ) {
        let pill = subjectPillImage(
            identity: FileVisualIdentity(path: attachment.displayName),
            text: "@\(attachment.displayName)",
            monospace: false,
            tint: .controlAccentColor
        )
        let cell = NSTextAttachment()
        cell.image = pill
        cell.bounds = NSRect(x: 0, y: -5, width: pill.size.width, height: pill.size.height)
        let start = result.length
        result.append(NSAttributedString(attachment: cell))
        if attachment.isHoverPreviewable {
            let range = NSRange(location: start, length: result.length - start)
            result.addAttribute(
                .oreAttachmentPreview,
                value: attachment.fileURL(worktreePath: worktreePath),
                range: range
            )
            result.addAttribute(.cursor, value: NSCursor.pointingHand, range: range)
        }
    }

    private static func badgeText(for row: TranscriptRow) -> String {
        // A message the engine queued behind an open turn has not reached the
        // agent yet. Saying so on the row is the difference between "waiting its
        // turn" and "sent, and ignored".
        if row.isQueued { return "QUEUED" }
        switch row.kind {
        // The visual treatment already says who is talking — a tinted block for
        // the user, plain prose for the agent — so "YOU"/"AGENT" on every row
        // was noise. Badges remain only where they carry something the styling
        // can't: which tool ran, and error / plan callouts.
        case .userMessage, .assistantText, .thinking, .divider, .activityGroup,
             .toolCall, .error, .turnFooter:
            return ""
        case .plan:
            return "PLAN"
        }
    }

    private static func font(for row: TranscriptRow) -> NSFont {
        switch row.kind {
        case .toolCall:
            return .monospacedSystemFont(ofSize: OreTheme.Font.caption, weight: .regular)
        case .activityGroup, .turnFooter:
            return .systemFont(ofSize: OreTheme.Font.caption, weight: .regular)
        case .thinking:
            return .systemFont(ofSize: OreTheme.Font.body)
        case .divider:
            return .systemFont(ofSize: OreTheme.Font.caption, weight: .medium)
        case .assistantText, .plan, .userMessage:
            return .systemFont(ofSize: OreTheme.Font.prose)
        default:
            return .systemFont(ofSize: OreTheme.Font.prose)
        }
    }

    private static func textColor(for row: TranscriptRow) -> NSColor {
        // Queued text is muted for the same reason its bubble is: it has been
        // written, but the agent has not read it yet.
        if row.isQueued { return .secondaryLabelColor }
        switch row.kind {
        case .thinking, .divider, .activityGroup, .turnFooter: return .secondaryLabelColor
        case .error: return .systemRed
        default: return .labelColor
        }
    }

    private static func background(for row: TranscriptRow) -> NSColor {
        // A queued message is drawn as a faint outline of the bubble it will
        // become, so it reads as waiting rather than as one more sent message
        // the agent has silently skipped over.
        if row.isQueued { return .controlAccentColor.withAlphaComponent(0.04) }
        switch row.kind {
        case .userMessage: return .controlAccentColor.withAlphaComponent(0.10)
        // Activity rows stay on the plain transcript — no full-width band. The
        // file/argument reads as a small outlined pill inside the line instead,
        // which is quieter and keeps the agent's prose dominant.
        case .toolCall: return .clear
        case .activityGroup: return .clear
        case .thinking: return .clear
        case .plan: return .systemPurple.withAlphaComponent(0.08)
        case .error: return .systemRed.withAlphaComponent(0.08)
        case .assistantText: return .clear
        case .divider: return .clear
        case .turnFooter: return .clear
        }
    }

    private struct ProcessPresentation {
        var icon: String
        var title: String
        var detail: String
        var tint: NSColor
        var fileIdentity: FileVisualIdentity?
        var subject: String? = nil
        var filePath: String? = nil
        var insertions = 0
        var deletions = 0
        var isDiff = false
    }

    /// A small rounded, tinted pill for a file reference or command argument,
    /// drawn as an image so it can sit inline in the attributed transcript text.
    ///
    /// Drawing happens inside an explicit appearance because `lockFocus()`
    /// resolves dynamic colours against whatever appearance is current and then
    /// freezes the result into a bitmap. Rendered while the app was dark, a
    /// pill keeps its white label forever — which, on a light transcript, is
    /// white on white: the chips simply vanish. The bitmap cache is keyed on
    /// the appearance for the same reason (see `RenderCache`).
    ///
    /// File chips pick up the language colour; tool chips use the tool tint.
    /// Edit/Write chips also carry +/− line counts so the size of the change
    /// is visible without expanding the row.
    private static func subjectPillImage(
        identity: FileVisualIdentity?,
        text: String,
        monospace: Bool,
        tint: NSColor,
        insertions: Int = 0,
        deletions: Int = 0
    ) -> NSImage {
        var image = NSImage()
        currentAppearance.performAsCurrentDrawingAppearance {
            image = drawSubjectPill(
                identity: identity,
                text: text,
                monospace: monospace,
                tint: tint,
                insertions: insertions,
                deletions: deletions
            )
        }
        return image
    }

    /// The appearance transcript bitmaps are rendered against.
    ///
    /// `NSApp.effectiveAppearance` rather than a view's: these are static
    /// drawing helpers with no view in scope, and the transcript never differs
    /// from the app's appearance anyway.
    static var currentAppearance: NSAppearance {
        NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua) ?? NSAppearance()
    }

    private static func drawSubjectPill(
        identity: FileVisualIdentity?,
        text: String,
        monospace: Bool,
        tint: NSColor,
        insertions: Int,
        deletions: Int
    ) -> NSImage {
        let font = monospace
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12, weight: .medium)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]
        let statFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: statFont, .foregroundColor: NSColor.systemGreen,
        ]
        let minusAttrs: [NSAttributedString.Key: Any] = [
            .font: statFont, .foregroundColor: NSColor.systemRed,
        ]
        let plusText = insertions > 0 ? "+\(insertions)" : ""
        let minusText = deletions > 0 ? "−\(deletions)" : ""
        let textSize = (text as NSString).size(withAttributes: textAttrs)
        let plusSize = (plusText as NSString).size(withAttributes: plusAttrs)
        let minusSize = (minusText as NSString).size(withAttributes: minusAttrs)
        let iconSize: CGFloat = identity != nil ? 14 : 0
        let iconGap: CGFloat = identity != nil ? 6 : 0
        let statGap: CGFloat = plusText.isEmpty && minusText.isEmpty ? 0 : 8
        let betweenStats: CGFloat = plusText.isEmpty || minusText.isEmpty ? 0 : 6
        // Roomier than the old candy-pill: a rounded rectangle (not a full
        // capsule) with generous horizontal padding and a neutral fill, so the
        // file's own icon colour carries the identity instead of tinting the
        // whole chip. Modelled on the file chips in editor review UIs.
        let hPad: CGFloat = 10
        let vPad: CGFloat = 5
        let width = ceil(
            hPad + iconSize + iconGap + textSize.width
                + statGap + plusSize.width + betweenStats + minusSize.width
                + hPad
        )
        let height = ceil(textSize.height + vPad * 2)
        let image = NSImage(size: NSSize(width: max(1, width), height: max(1, height)))
        image.lockFocus()
        let rect = NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: OreTheme.chipRadius, yRadius: OreTheme.chipRadius)
        let fill = identity == nil
            ? tint.withAlphaComponent(0.16)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.10)
        fill.setFill()
        path.fill()
        path.lineWidth = 1
        if identity == nil {
            tint.withAlphaComponent(0.35).setStroke()
        } else {
            NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        }
        path.stroke()
        var x = hPad
        if let identity {
            let iconRect = NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
            drawFileIcon(identity, in: iconRect)
            x += iconSize + iconGap
        }
        (text as NSString).draw(
            at: NSPoint(x: x, y: (height - textSize.height) / 2),
            withAttributes: textAttrs
        )
        x += textSize.width
        if !plusText.isEmpty {
            x += statGap
            (plusText as NSString).draw(
                at: NSPoint(x: x, y: (height - plusSize.height) / 2),
                withAttributes: plusAttrs
            )
            x += plusSize.width
        }
        if !minusText.isEmpty {
            x += plusText.isEmpty ? statGap : betweenStats
            (minusText as NSString).draw(
                at: NSPoint(x: x, y: (height - minusSize.height) / 2),
                withAttributes: minusAttrs
            )
        }
        image.unlockFocus()
        return image
    }

    /// Language glyphs already carry colour; SF Symbol templates need a tint
    /// pass so a Swift file doesn't render as a grey blob inside a coloured chip.
    private static func drawFileIcon(_ identity: FileVisualIdentity, in rect: NSRect) {
        let icon = identity.appKitImage(size: rect.width)
        if icon.isTemplate {
            let tinted = NSImage(size: rect.size, flipped: false) { bounds in
                icon.draw(in: bounds)
                identity.tone.nsColor.set()
                bounds.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect)
        } else {
            icon.draw(in: rect)
        }
    }

    private static func processText(for row: TranscriptRow, worktreePath: String = "") -> NSAttributedString {
        let item = processPresentation(for: row)
        let result = NSMutableAttributedString()
        let processImage = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))?
            .withSymbolConfiguration(.init(paletteColors: [item.tint]))
        if let image = processImage {
            image.isTemplate = false
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }
        result.append(NSAttributedString(
            string: item.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: item.tint,
            ]
        ))
        if let subject = item.subject, !subject.isEmpty {
            result.append(NSAttributedString(string: "  "))
            let subjectStart = result.length
            let pill = subjectPillImage(
                identity: item.fileIdentity,
                text: compact(subject, limit: 64),
                monospace: item.fileIdentity == nil,
                tint: item.tint,
                insertions: item.insertions,
                deletions: item.deletions
            )
            let attachment = NSTextAttachment()
            attachment.image = pill
            let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            attachment.bounds = NSRect(
                x: 0,
                y: (titleFont.capHeight - pill.size.height) / 2,
                width: pill.size.width,
                height: pill.size.height
            )
            result.append(NSAttributedString(attachment: attachment))
            if let path = item.filePath {
                let chipRange = NSRange(location: subjectStart, length: result.length - subjectStart)
                if let url = MarkdownRenderer.fileReferenceURL(path) {
                    result.addAttribute(.link, value: url, range: chipRange)
                }
                if let preview = hoverPreviewURL(for: path, worktreePath: worktreePath) {
                    result.addAttribute(.oreAttachmentPreview, value: preview, range: chipRange)
                    result.addAttribute(.cursor, value: NSCursor.pointingHand, range: chipRange)
                }
            }
        } else if item.insertions > 0 || item.deletions > 0 {
            if item.insertions > 0 {
                result.append(NSAttributedString(
                    string: "  +\(item.insertions)",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: NSColor.systemGreen,
                    ]
                ))
            }
            if item.deletions > 0 {
                result.append(NSAttributedString(
                    string: "  −\(item.deletions)",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: NSColor.systemRed,
                    ]
                ))
            }
        }
        // A subagent (Task) row is a collapsible group: show how many steps ran
        // inside it and a disclosure chevron, and stop here — its children are
        // separate rows below, so the noisy launch blob isn't worth showing.
        if let steps = row.subagentChildCount {
            result.append(NSAttributedString(
                string: "  · \(steps) step\(steps == 1 ? "" : "s")",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            result.append(NSAttributedString(
                string: row.isExpanded ? "   ⌄" : "   ›",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
            ))
            return result
        }
        if !item.detail.isEmpty {
            result.append(NSAttributedString(
                string: row.isExpanded ? "   ⌄" : "   ›",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }
        guard row.isExpanded, !item.detail.isEmpty else { return result }
        result.append(NSAttributedString(string: "\n\n"))
        let lines = item.detail.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let value = String(line)
            let color: NSColor
            if item.isDiff && value.hasPrefix("+") && !value.hasPrefix("+++") { color = .systemGreen }
            else if item.isDiff && (value.hasPrefix("-") || value.hasPrefix("−")) && !value.hasPrefix("---") { color = .systemRed }
            else { color = .secondaryLabelColor }
            result.append(NSAttributedString(
                string: value + (index == lines.count - 1 ? "" : "\n"),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: color]
            ))
        }
        return result
    }

    private static func activityGroupText(for row: TranscriptRow) -> NSAttributedString {
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: row.isExpanded ? "⌄  " : "›  ",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor]
        ))
        result.append(NSAttributedString(string: row.text, attributes: secondary))

        // How long the turn's activity took, from its first to last event.
        if let first = row.groupedRows.first?.createdAt,
           let last = row.groupedRows.last?.createdAt,
           last.timeIntervalSince(first) >= 1 {
            result.append(NSAttributedString(
                string: "  ·  \(elapsedLabel(last.timeIntervalSince(first)))",
                attributes: secondary
            ))
        }

        // The icon and file-pill summaries stand in for the work while it's
        // folded away; once expanded, every tool row shows its own icon and
        // chip in the right place, so repeating them on the header is just
        // noise. Collapsed only.
        guard !row.isExpanded else { return result }

        var seenIcons: Set<String> = []
        for child in row.groupedRows {
            let icon = processPresentation(for: child).icon
            guard seenIcons.insert(icon).inserted else { continue }
            guard let image = NSImage(
                systemSymbolName: icon,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 10.5, weight: .regular))?
                .withSymbolConfiguration(.init(paletteColors: [NSColor.secondaryLabelColor]))
            else { continue }
            image.isTemplate = false
            result.append(NSAttributedString(string: "   "))
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 12, height: 12)
            result.append(NSAttributedString(attachment: attachment))
            if seenIcons.count == 6 { break }
        }
        // The files this turn changed used to hang off this line too. They
        // belong to the turn, not to its hidden work, so they live in the
        // footer now — where they stay visible whether or not the section is
        // expanded.
        return result
    }

    /// The closing line of a finished turn: how long it took and what it
    /// actually changed.
    ///
    /// The same facts are available by expanding the activity section and
    /// reading every Edit, which is precisely the work this saves. Files come
    /// from the turn's own edit calls rather than the working tree, so the line
    /// keeps describing *that* turn after later turns change more.
    private static func turnFooterText(for row: TranscriptRow) -> NSAttributedString {
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let result = NSMutableAttributedString()

        if let first = row.groupedRows.first?.createdAt,
           let last = row.groupedRows.last?.createdAt,
           last.timeIntervalSince(first) >= 1 {
            result.append(NSAttributedString(
                string: elapsedLabel(last.timeIntervalSince(first)),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }

        let changed = changedFiles(in: row.groupedRows)
        if changed.isEmpty {
            if result.length == 0 {
                result.append(NSAttributedString(string: "No files changed", attributes: secondary))
            }
            return result
        }

        if result.length > 0 { result.append(NSAttributedString(string: "   ", attributes: secondary)) }
        for (index, file) in changed.prefix(8).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "   ", attributes: secondary)) }
            // The chip carries its own +/− counts, so the footer doesn't append
            // them again alongside it.
            let pill = Self.wrappingChipImage(subjectPillImage(
                identity: FileVisualIdentity(path: file.path),
                text: (file.path as NSString).lastPathComponent,
                monospace: false,
                tint: .systemOrange,
                insertions: file.insertions,
                deletions: file.deletions
            ))
            let attachment = NSTextAttachment()
            attachment.image = pill
            let rowFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
            attachment.bounds = NSRect(
                x: 0,
                y: (rowFont.capHeight - pill.size.height) / 2,
                width: pill.size.width,
                height: pill.size.height
            )
            let start = result.length
            result.append(NSAttributedString(attachment: attachment))
            if let url = MarkdownRenderer.fileReferenceURL(file.path) {
                result.addAttribute(
                    .link, value: url, range: NSRange(location: start, length: result.length - start)
                )
            }
        }
        if changed.count > 8 {
            result.append(NSAttributedString(
                string: "   +\(changed.count - 8) more", attributes: secondary
            ))
        }
        return result
    }

    /// Extra height around a wrapping footer chip. Half sits above the stroke
    /// and half below, so two stacked rows have a visible gutter instead of
    /// sharing an edge. Applied in the bitmap because TextKit scales an
    /// attachment to `bounds` — padding the rect would stretch the chip.
    private static let footerChipRowGap: CGFloat = 6

    private static func wrappingChipImage(_ pill: NSImage) -> NSImage {
        let gap = footerChipRowGap
        let size = NSSize(width: pill.size.width, height: pill.size.height + gap)
        return NSImage(size: size, flipped: false) { _ in
            pill.draw(
                in: NSRect(x: 0, y: gap / 2, width: pill.size.width, height: pill.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
    }

    private struct ChangedFile { var path: String; var insertions: Int; var deletions: Int }

    /// Aggregates the edit/write tool calls in a turn into a per-file changed
    /// list with summed insertion/deletion counts.
    private static func changedFiles(in rows: [TranscriptRow]) -> [ChangedFile] {
        var order: [String] = []
        var totals: [String: (Int, Int)] = [:]
        for row in rows where row.kind == .toolCall {
            let item = processPresentation(for: row)
            guard item.isDiff, let path = item.filePath, !path.isEmpty else { continue }
            if totals[path] == nil { order.append(path) }
            let current = totals[path] ?? (0, 0)
            totals[path] = (current.0 + item.insertions, current.1 + item.deletions)
        }
        return order.map { ChangedFile(path: $0, insertions: totals[$0]!.0, deletions: totals[$0]!.1) }
    }

    private static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    private static func processPresentation(for row: TranscriptRow) -> ProcessPresentation {
        if row.kind == .thinking {
            let detail = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = compact(detail.split(separator: "\n").first.map(String.init) ?? "Reasoning")
            return ProcessPresentation(icon: "brain.head.profile", title: preview.isEmpty ? "Thinking" : "Thinking · \(preview)", detail: detail, tint: .secondaryLabelColor)
        }
        if row.kind == .error || (row.isError && meaningful(row.resultText ?? row.text)) {
            let detail = (row.resultText?.isEmpty == false ? row.resultText : row.text) ?? row.text
            return ProcessPresentation(icon: "exclamationmark.triangle.fill", title: "Error", detail: detail, tint: .systemRed)
        }

        let tool = (row.toolName ?? "").lowercased()
        let key = ((row.toolName ?? "") + " " + row.text).lowercased()
        let input = row.toolInput

        // The agent's own checklist. These used to fall through to the generic
        // gear, so a row said "TaskUpdate" and nothing else — the one thing it
        // could not tell you was which task. The subject is carried on the row
        // (resolved from the TaskCreate that named it) because an update
        // identifies its task by id alone.
        if let checklist = checklistPresentation(tool: tool, row: row, input: input) {
            return checklist
        }

        // Subagent tasks are a first-class thing the harness does, so they get
        // their own icon and read "created" while running, "completed" once the
        // result attaches — not the generic gear fallback.
        if tool == "task" || tool.hasSuffix("_task") || tool.contains("subagent") {
            let subagentType = input?["subagent_type"]?.stringValue
            let description = input?["description"]?.stringValue ?? row.text
            let prompt = input?["prompt"]?.stringValue ?? description
            let done = row.isComplete && !row.isError
            // The Task result is often just the harness's internal launch blob
            // ("Async agent launched… agentId… output_file… Do NOT Read…").
            // That is noise, so fall back to the subagent's instructions when the
            // result is that metadata rather than a real report.
            let resultText = row.resultText ?? ""
            let isLaunchMetadata = resultText.contains("Async agent launched")
                || resultText.contains("agentId:")
                || resultText.contains("output_file:")
            let detail = (resultText.isEmpty || isLaunchMetadata) ? prompt : resultText
            let title: String
            if row.isError { title = "Subagent failed" }
            else if done { title = "Subagent finished" }
            else { title = subagentType.map { "Subagent · \($0)" } ?? "Subagent" }
            return ProcessPresentation(
                icon: row.isError ? "exclamationmark.triangle.fill"
                    : done ? "checkmark.seal.fill" : "sparkles",
                title: title,
                detail: detail,
                tint: row.isError ? .systemRed
                    : done ? .systemGreen : .controlAccentColor,
                subject: compact(description, limit: 64)
            )
        }

        // Todo/plan checklists the agent maintains as it works.
        if tool.contains("todo") {
            return ProcessPresentation(
                icon: "checklist",
                title: "Updated plan",
                detail: row.resultText ?? row.text,
                tint: .systemPurple
            )
        }

        // Cursor (and similar) lints/list/delete calls must be classified
        // before the generic "read"/"file" matchers — "ReadLints" contains
        // "read" and would otherwise show as a file read.
        if tool.contains("lint") {
            let path = input?["file_path"]?.stringValue ?? input?["path"]?.stringValue
            return ProcessPresentation(
                icon: "checkmark.seal",
                title: "Lints",
                detail: row.resultText ?? path ?? row.text,
                tint: row.isError ? .systemRed : .systemTeal,
                fileIdentity: path.map { FileVisualIdentity(path: $0) },
                subject: path.map { ($0 as NSString).lastPathComponent } ?? compact(row.text),
                filePath: path
            )
        }
        if tool == "ls" || tool == "list" {
            let path = input?["file_path"]?.stringValue ?? input?["path"]?.stringValue
            return ProcessPresentation(
                icon: "folder",
                title: "List",
                detail: row.resultText ?? path ?? row.text,
                tint: .systemBlue,
                fileIdentity: path.map { FileVisualIdentity(path: $0, isDirectory: true) },
                subject: path.map { ($0 as NSString).lastPathComponent } ?? compact(row.text),
                filePath: path
            )
        }
        if tool == "delete" || tool == "remove" {
            let path = input?["file_path"]?.stringValue ?? input?["path"]?.stringValue
            return ProcessPresentation(
                icon: "trash",
                title: "Delete",
                detail: row.resultText ?? path ?? row.text,
                tint: row.isError ? .systemRed : .systemOrange,
                fileIdentity: path.map { FileVisualIdentity(path: $0) },
                subject: path.map { ($0 as NSString).lastPathComponent } ?? compact(row.text),
                filePath: path
            )
        }

        let directPath = input?["file_path"]?.stringValue
            ?? input?["path"]?.stringValue
            ?? input?[0]?["path"]?.stringValue
        let patchText = input?["patch"]?.stringValue
            ?? input?["diff"]?.stringValue
            ?? input?["input"]?.stringValue
        let patchPaths = patchText.map(patchFilePaths) ?? []
        let path = directPath ?? patchPaths.first
        let fileName = path.map { ($0 as NSString).lastPathComponent }
        let resultText = row.resultText ?? ""

        if key.contains("edit") || key.contains("write") || key.contains("patch") {
            let resultDiff = ToolChangeStats.looksLikeDiff(resultText) ? resultText : nil
            let suppliedDiff = patchText ?? input?[0]?["diff"]?.stringValue ?? resultDiff
            let old = input?["old_string"]?.stringValue ?? input?["oldString"]?.stringValue
            let new = input?["new_string"]?.stringValue ?? input?["newString"]?.stringValue
            let content = input?["content"]?.stringValue ?? input?["contents"]?.stringValue
            let diff = suppliedDiff ?? {
                var parts: [String] = []
                if let old { parts.append(Self.prefixedLines(old, prefix: "- ")) }
                if let new { parts.append(Self.prefixedLines(new, prefix: "+ ")) }
                return parts.joined(separator: "\n")
            }()
            let changeKind = input?[0]?["kind"]?["type"]?.stringValue
                ?? input?["kind"]?["type"]?.stringValue
            let isWrite = key.contains("write") || changeKind == "add"
            let counts = ToolChangeStats.lineCounts(
                diff: suppliedDiff ?? "",
                old: old,
                new: new,
                content: content,
                changeKind: changeKind,
                isWrite: isWrite
            )
            return ProcessPresentation(
                icon: isWrite ? "doc.badge.plus" : "pencil.line",
                title: isWrite ? "Write" : "Edit",
                detail: diff.isEmpty ? (content ?? resultText) : diff,
                tint: row.isError ? .systemRed : (isWrite ? .systemGreen : .systemOrange),
                fileIdentity: path.map { FileVisualIdentity(path: $0) },
                subject: patchPaths.count > 1 ? "\(patchPaths.count) files" : fileName ?? compact(row.text),
                filePath: patchPaths.count <= 1 ? path : nil,
                insertions: counts.insertions, deletions: counts.deletions, isDiff: true
            )
        }
        if key.contains("bash") || key.contains("shell") || key.contains("command") || key.contains("exec") {
            let command = input?["command"]?.stringValue ?? input?["cmd"]?.stringValue ?? row.text
            let commandPaths = referencedFilePaths(in: command)
            let commandPath = commandPaths.count == 1 ? commandPaths[0] : nil
            let commandFileName = commandPath.map { ($0 as NSString).lastPathComponent }
            let lower = command.lowercased()
            let looksLikeSearch = lower.contains("rg ") || lower.contains("grep ")
                || lower.contains("find ") || key.contains("search")
            let looksLikeRead = key.contains("read") || lower.contains("cat ")
                || lower.contains("head ") || lower.contains("tail ")
                || lower.contains("sed -n") || lower.contains("nl -")
            if let commandPath,
               ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(
                    (commandPath as NSString).pathExtension.lowercased()
               ) {
                return ProcessPresentation(
                    icon: "photo", title: "Read image",
                    detail: resultText.isEmpty ? command : resultText,
                    tint: .systemPurple,
                    fileIdentity: FileVisualIdentity(path: commandPath),
                    subject: commandFileName,
                    filePath: commandPath
                )
            }
            if looksLikeRead, let commandPath {
                let lineCount = resultText.isEmpty ? nil : resultText.split(separator: "\n").count
                return ProcessPresentation(
                    icon: "doc.text",
                    title: lineCount.map { "Read \($0) lines" } ?? "Read",
                    detail: resultText.isEmpty ? command : resultText,
                    tint: .systemBlue,
                    fileIdentity: FileVisualIdentity(path: commandPath),
                    subject: commandFileName,
                    filePath: commandPath
                )
            }
            if looksLikeSearch {
                return ProcessPresentation(
                    icon: "magnifyingglass", title: "Search",
                    detail: resultText.isEmpty ? command : resultText,
                    tint: .systemPurple,
                    subject: compact(command.split(separator: "\n").first.map(String.init) ?? command)
                )
            }
            let summary = compact(command.split(separator: "\n").first.map(String.init) ?? command)
            return ProcessPresentation(
                icon: "terminal",
                title: "Bash",
                detail: resultText.isEmpty ? command : resultText,
                tint: row.isError ? .systemRed : .systemTeal,
                subject: summary
            )
        }
        if key.contains("image") || ["png", "jpg", "jpeg", "gif", "webp"].contains((path as NSString?)?.pathExtension.lowercased() ?? "") {
            return ProcessPresentation(
                icon: "photo", title: "Read image",
                detail: path ?? resultText, tint: .systemPurple,
                fileIdentity: path.map { FileVisualIdentity(path: $0) },
                subject: fileName, filePath: path
            )
        }
        if key.contains("read") || key.contains("file") {
            let lineCount = resultText.isEmpty ? input?["limit"]?.intValue : resultText.split(separator: "\n").count
            let count = lineCount.map { "\($0) lines " } ?? ""
            return ProcessPresentation(
                icon: "doc.text",
                title: "Read \(count)".trimmingCharacters(in: .whitespaces),
                detail: resultText.isEmpty ? (path ?? row.text) : resultText,
                tint: .systemBlue,
                fileIdentity: path.map { FileVisualIdentity(path: $0) },
                subject: fileName ?? compact(row.text),
                filePath: path
            )
        }
        if key.contains("web") || key.contains("fetch") || input?["url"]?.stringValue != nil {
            let url = input?["url"]?.stringValue ?? input?["query"]?.stringValue ?? row.text
            return ProcessPresentation(icon: "globe", title: "Fetch", detail: resultText, tint: .systemCyan, subject: compact(url))
        }
        if key.contains("search") || key.contains("grep") || key.contains("glob") {
            let query = input?["query"]?.stringValue ?? input?["q"]?.stringValue ?? input?["pattern"]?.stringValue ?? row.text
            return ProcessPresentation(icon: "magnifyingglass", title: "Search", detail: resultText, tint: .systemPurple, subject: compact(query))
        }
        return ProcessPresentation(icon: "gearshape", title: row.text, detail: resultText, tint: row.isError ? .systemRed : .secondaryLabelColor)
    }

    /// Hover preview for image chips and pasted-text dumps in tool rows.
    /// Workspace source-file chips stay click-to-open only — previewing a
    /// whole Swift file on hover would be noise.
    private static func hoverPreviewURL(for path: String, worktreePath: String) -> URL? {
        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
            .contains(ext)
        let isPastedText = path.hasPrefix(".context/attachments/")
            && ["txt", "md", "markdown", "json", "csv", "log", "xml", "yml", "yaml",
                "html", "css", "toml", "ini", "env", "sh"].contains(ext)
        guard isImage || isPastedText else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        guard !worktreePath.isEmpty else { return nil }
        return URL(fileURLWithPath: worktreePath).appendingPathComponent(path)
    }

    /// The agent's task list, as a row that names the task it touched.
    ///
    /// Returns nil for anything that isn't one of these tools, so the caller
    /// falls through to its normal matching.
    private static func checklistPresentation(
        tool: String,
        row: TranscriptRow,
        input: JSONValue?
    ) -> ProcessPresentation? {
        let subject = row.resolvedSubject
            ?? input?["subject"]?.stringValue
            ?? input?["taskId"]?.stringValue.map { "Task \($0)" }

        // Matched by suffix so the MCP-namespaced spelling
        // (`mcp__ore__TaskUpdate`) lands on the same presentation.
        let name = ["taskcreate", "taskupdate", "tasklist", "taskget"]
            .first { tool.hasSuffix($0) }
        switch name {
        case "taskcreate":
            return ProcessPresentation(
                icon: "plus.circle", title: "Task added",
                detail: row.resultText ?? "", tint: .controlAccentColor,
                subject: subject.map { compact($0, limit: 72) }
            )
        case "taskupdate":
            let status = input?["status"]?.stringValue ?? ""
            let (icon, title, tint): (String, String, NSColor) = switch status {
            case "completed": ("checkmark.circle.fill", "Task completed", .systemGreen)
            case "in_progress": ("circle.lefthalf.filled", "Task started", .controlAccentColor)
            case "pending": ("circle", "Task reopened", .secondaryLabelColor)
            case "deleted": ("trash", "Task removed", .secondaryLabelColor)
            default: ("pencil.circle", "Task updated", .secondaryLabelColor)
            }
            return ProcessPresentation(
                icon: icon, title: title,
                detail: row.resultText ?? "", tint: row.isError ? .systemRed : tint,
                subject: subject.map { compact($0, limit: 72) }
            )
        case "tasklist", "taskget":
            return ProcessPresentation(
                icon: "checklist", title: name == "tasklist" ? "Reviewed tasks" : "Read task",
                detail: row.resultText ?? "", tint: .secondaryLabelColor,
                subject: subject.map { compact($0, limit: 72) }
            )
        default:
            return nil
        }
    }

    private static func meaningful(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !value.isEmpty && !["null", "nil", "<null>", "(null)", "\"null\""].contains(value)
    }

    private static func compact(_ text: String, limit: Int = 110) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private static func prefixedLines(_ text: String, prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }

    private static func patchFilePaths(in patch: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?m)^\*\*\* (?:Update|Add|Delete) File: (.+)$"#
        ) else { return [] }
        let source = patch as NSString
        var seen: Set<String> = []
        return expression.matches(
            in: patch,
            range: NSRange(location: 0, length: source.length)
        ).compactMap { match in
            let path = source.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return seen.insert(path).inserted ? path : nil
        }
    }

    private static func referencedFilePaths(in command: String) -> [String] {
        let extensions = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "cs", "go", "rs", "java", "kt",
            "js", "jsx", "ts", "tsx", "py", "rb", "php", "sh", "sql", "html", "css", "scss",
            "vue", "svelte", "json", "jsonl", "yaml", "yml", "toml", "xml", "md", "plist",
        ].joined(separator: "|")
        let pattern = #"(?:/?(?:[A-Za-z0-9_.@+\-]+/)+)?[A-Za-z0-9_.@+\-]+\.(?:"#
            + extensions + #")"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = command as NSString
        var seen: Set<String> = []
        return expression.matches(
            in: command,
            range: NSRange(location: 0, length: source.length)
        ).compactMap { match in
            let path = source.substring(with: match.range)
            return seen.insert(path).inserted ? path : nil
        }
    }
}

/// Line-change counts for Edit/Write tool chips.
///
/// Claude Code's Edit tool sends `old_string`/`new_string`, not a unified
/// diff. Counting only lines that start with `+`/`-` therefore reported
/// nothing. Write sends `content`. Codex file-change items send a raw snippet
/// plus `kind: add|delete`. This collapses those shapes into one pair of
/// numbers the chip can show.
enum ToolChangeStats {
    static func lineCounts(
        diff: String,
        old: String?,
        new: String?,
        content: String?,
        changeKind: String?,
        isWrite: Bool
    ) -> (insertions: Int, deletions: Int) {
        if let old, let new {
            return (lineCount(new), lineCount(old))
        }

        let plus = unifiedCount(diff, added: true)
        let minus = unifiedCount(diff, added: false)
        if plus > 0 || minus > 0 {
            return (plus, minus)
        }

        if isWrite || changeKind == "add" {
            let text = content ?? new ?? diff
            return (max(lineCount(text), text.isEmpty ? 0 : 1), 0)
        }
        if changeKind == "delete" {
            let text = content ?? old ?? diff
            return (0, max(lineCount(text), text.isEmpty ? 0 : 1))
        }
        if let new, !new.isEmpty {
            return (lineCount(new), 0)
        }
        if let content, !content.isEmpty {
            return (lineCount(content), 0)
        }
        return (0, 0)
    }

    static func looksLikeDiff(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("diff --git") { return true }
        if trimmed.contains("*** Begin Patch") { return true }
        if trimmed.contains("*** Update File:")
            || trimmed.contains("*** Add File:")
            || trimmed.contains("*** Delete File:") {
            return true
        }
        if trimmed.hasPrefix("@@ ") || trimmed.contains("\n@@ ") { return true }
        let hasMinusHeader = trimmed.hasPrefix("--- ") || trimmed.contains("\n--- ")
        let hasPlusHeader = trimmed.contains("\n+++ ") || trimmed.hasPrefix("+++ ")
        return hasMinusHeader && hasPlusHeader
    }

    static func lineCount(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        if trimmed.isEmpty { return 1 }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private static func unifiedCount(_ diff: String, added: Bool) -> Int {
        diff.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let value = String(line)
            if added {
                return value.hasPrefix("+") && !value.hasPrefix("+++")
            }
            return (value.hasPrefix("-") || value.hasPrefix("−")) && !value.hasPrefix("---")
        }.count
    }
}

/// The transcript's text view: read-only and selectable, but it also carries
/// the row's click gestures, so tapping the text still toggles an activity
/// group (single click) or reverts to a checkpoint (double click) exactly as
/// the enclosing cell used to. Without this, making the text selectable would
/// have swallowed those clicks into a text selection. Image and pasted-text
/// chips and `@` tokens use the same hover preview as the composer.
private final class TranscriptTextView: NSTextView, NSTextViewDelegate {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onOpenFile: ((String) -> Void)?
    /// Agent-busy: don't TextKit-hit-test on every mouseMoved. Those events
    /// queued ahead of clicks and are a large part of "the close button does
    /// nothing until I click twice."
    var skipHoverTracking = false

    private var hoverTracking: NSTrackingArea?
    private let attachmentPreview = AttachmentPreviewController()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let options: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !skipHoverTracking else { return }
        updateAttachmentPreview(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        dismissAttachmentPreview()
    }

    func dismissAttachmentPreview() {
        attachmentPreview.dismiss()
    }

    override func mouseDown(with event: NSEvent) {
        // Let NSTextView dispatch links before the row's expand/collapse click.
        // This makes file chips inside process rows actionable as well.
        if link(at: event) != nil {
            super.mouseDown(with: event)
            return
        }
        if let onSingleClick {
            onSingleClick()
            return
        }
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        super.mouseDown(with: event)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "ore-file",
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value
        else { return false }
        onOpenFile?(path)
        return true
    }

    private func updateAttachmentPreview(at point: NSPoint) {
        guard let textStorage,
              let character = AttachmentHoverHitTesting.characterIndex(at: point, in: self)
        else {
            dismissAttachmentPreview()
            return
        }
        var range = NSRange()
        guard let url = textStorage.attribute(
            .oreAttachmentPreview,
            at: character,
            effectiveRange: &range
        ) as? URL,
              let anchor = AttachmentHoverHitTesting.anchor(
                for: range, at: point, in: self
              ) else {
            dismissAttachmentPreview()
            return
        }
        attachmentPreview.show(url: url, from: self, anchor: anchor)
    }

    private func link(at event: NSEvent) -> Any? {
        guard let layoutManager, let textContainer, let textStorage,
              textStorage.length > 0 else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        let point = NSPoint(
            x: location.x - textContainerOrigin.x,
            y: location.y - textContainerOrigin.y
        )
        guard layoutManager.usedRect(for: textContainer).contains(point) else { return nil }
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < textStorage.length else { return nil }
        return textStorage.attribute(.link, at: character, effectiveRange: nil)
    }

    override var acceptsFirstResponder: Bool { isSelectable }
}
