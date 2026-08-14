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
    var rows: [TranscriptRow]
    var persistenceKey: String
    var onRevert: (TurnID) -> Void
    var onToggleActivity: (String) -> Void
    var onOpenFile: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            persistenceKey: persistenceKey,
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

        let column = NSTableColumn(identifier: .init("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // The busy pill overlays the bottom-left of the transcript. Permanent
        // bottom breathing room means it never covers the latest line and its
        // appearance cannot push the document around while text streams.
        scrollView.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 46, right: 0)

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

        let container = TranscriptContainerView(scrollView: scrollView)
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
        let persistenceKey: String

        private var rows: [TranscriptRow] = []
        /// Height per row id. Measuring a row means laying out its text, which
        /// is the single most expensive thing this view does, so it happens
        /// once per (row, width) rather than on every scroll tick.
        private var heightCache: [String: CGFloat] = [:]
        private var cachedWidth: CGFloat = 0

        init(
            persistenceKey: String,
            onRevert: @escaping (TurnID) -> Void,
            onToggleActivity: @escaping (String) -> Void,
            onOpenFile: @escaping (String) -> Void
        ) {
            self.persistenceKey = persistenceKey
            self.onRevert = onRevert
            self.onToggleActivity = onToggleActivity
            self.onOpenFile = onOpenFile
        }

        func update(rows newRows: [TranscriptRow]) {
            guard let tableView else { return }

            let wasAtBottom = isScrolledToBottom(tableView)
            let previous = rows
            rows = newRows

            // Streaming appends to the last row far more often than it adds
            // one. Reloading only what changed is what keeps a long transcript
            // responsive while text arrives.
            if previous.count == newRows.count {
                var changed: IndexSet = []
                for index in newRows.indices
                where previous[index].text != newRows[index].text
                    || previous[index].resultText != newRows[index].resultText
                    || previous[index].isComplete != newRows[index].isComplete
                    || previous[index].isExpanded != newRows[index].isExpanded
                    || previous[index].toolInput != newRows[index].toolInput
                    || previous[index].resultMetadata != newRows[index].resultMetadata
                    || previous[index].activitySignature != newRows[index].activitySignature {
                    heightCache.removeValue(forKey: newRows[index].id)
                    changed.insert(index)
                }
                guard !changed.isEmpty else { return }
                // The growing last row must not animate its height change. The
                // default row-height animation reflows the paragraph the reader
                // is mid-way through on every streaming delta, which is the
                // "bouncing" that makes the final response hard to read. A
                // zero-duration context applies the new height in place instead.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    tableView.noteHeightOfRows(withIndexesChanged: changed)
                }
                tableView.reloadData(
                    forRowIndexes: changed,
                    columnIndexes: IndexSet(integer: 0)
                )
            } else if newRows.count > previous.count,
                      previous.elementsEqualByID(newRows.prefix(previous.count)) {
                // Rows appended: insert rather than reload the whole table.
                let added = IndexSet(previous.count..<newRows.count)
                tableView.insertRows(at: added, withAnimation: [])
            } else {
                heightCache.removeAll()
                tableView.reloadData()
            }

            container?.turnRail.update(
                turnRows: newRows.indices.filter { newRows[$0].kind == .userMessage },
                totalRows: newRows.count
            )

            if previous.isEmpty, !newRows.isEmpty,
               let scrollView = tableView.enclosingScrollView {
                let saved = UserDefaults.standard.double(forKey: persistenceKey)
                if saved > 0 {
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: saved))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    return
                }
            }

            // Follow the conversation only if the user was already at the
            // bottom; yanking them back while they read is worse than not
            // following at all.
            if wasAtBottom { scrollToBottom(tableView) }
        }

        @objc func viewDidResize(_ notification: Notification) {
            guard let tableView else { return }
            let width = tableView.bounds.width
            guard abs(width - cachedWidth) > 1 else { return }
            cachedWidth = width
            heightCache.removeAll()
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(rows.indices))
        }

        @objc func scrollDidChange(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView else { return }
            UserDefaults.standard.set(clip.bounds.origin.y, forKey: persistenceKey)
            updateActiveTurn()
        }

        // MARK: - Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 20 }
            let item = rows[row]
            if let cached = heightCache[item.id] { return cached }

            let width = min(
                max(tableView.bounds.width - TranscriptCell.horizontalInset * 2, 100),
                TranscriptCell.contentMaxWidth
            )
            let height = TranscriptCell.height(for: item, width: width)
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
                onRevert: onRevert,
                onToggleActivity: onToggleActivity,
                onOpenFile: onOpenFile
            )
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        // MARK: - Scrolling

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
            // steady at the foot of the transcript. Layout first so the row's
            // freshly-changed height is reflected in the measurement.
            tableView.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            let targetY = max(0, tableView.bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(clip)
        }

        func scroll(to row: Int) {
            guard let tableView, rows.indices.contains(row) else { return }
            tableView.scrollRowToVisible(row)
        }

        private func updateActiveTurn() {
            guard let tableView, let rail = container?.turnRail else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            let middle = visible.location + max(visible.length / 2, 0)
            rail.activeRow = rail.turnRows.min {
                abs($0 - middle) < abs($1 - middle)
            }
        }
    }
}

/// Hosts the virtualized transcript and a compact turn minimap. Each marker is
/// one user prompt, making long conversations directly navigable without
/// replacing the native scrollbar or stealing its gestures.
final class TranscriptContainerView: NSView {
    let scrollView: NSScrollView
    let turnRail = TurnRailView()

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
    var activeRow: Int? { didSet { needsDisplay = true } }
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

/// One transcript row, drawn with TextKit.
final class TranscriptCell: NSTableCellView {
    static let horizontalInset: CGFloat = 24
    static let contentMaxWidth: CGFloat = 920
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
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var preferredWidthConstraint: NSLayoutConstraint!
    private var userWidthConstraint: NSLayoutConstraint!
    private var revertAction: (() -> Void)?
    private var toggleActivityAction: (() -> Void)?
    private let copyButton = NSButton()
    private var copyableText = ""
    private var isUserMessage = false
    private var copyTrackingArea: NSTrackingArea?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
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
        addLayoutGuide(contentGuide)

        indentGuide.wantsLayer = true
        indentGuide.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
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
            bubble.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),

            badge.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 6),

            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
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
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(
        with row: TranscriptRow,
        onRevert: @escaping (TurnID) -> Void,
        onToggleActivity: @escaping (String) -> Void,
        onOpenFile: @escaping (String) -> Void
    ) {
        let badgeString = Self.badgeText(for: row)
        badge.stringValue = badgeString
        badge.isHidden = badgeString.isEmpty
        badgeHeightZero.isActive = badgeString.isEmpty

        let isUser = row.kind == .userMessage
        copyableText = row.text
        isUserMessage = isUser
        // The copy button belongs to user messages; it stays hidden until the
        // row is hovered (see mouseEntered/Exited).
        if !isUser { copyButton.isHidden = true }
        let indent = row.parentToolCallID != nil ? Self.subagentIndent : 0
        leadingConstraint.constant = indent
        indentGuide.isHidden = indent == 0
        leadingConstraint.isActive = !isUser
        trailingConstraint.isActive = isUser
        preferredWidthConstraint.isActive = !isUser
        userWidthConstraint.isActive = isUser

        if isUser {
            let natural = Self.attributedText(for: row).boundingRect(
                with: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width + 20
            userWidthConstraint.constant = min(max(120, ceil(natural)), 620)
        }

        let attributedText = Self.attributedText(for: row)
        label.textStorage?.setAttributedString(attributedText)
        label.onOpenFile = onOpenFile
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

        bubble.layer?.backgroundColor = Self.background(for: row).cgColor
        bubble.layer?.borderWidth = 0
        bubble.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        revertAction = { onRevert(row.turnID) }
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

    static func height(for row: TranscriptRow, width: CGFloat) -> CGFloat {
        if row.kind == .divider { return 42 }
        let attributed = attributedText(for: row)
        let indent = row.parentToolCallID != nil ? subagentIndent : 0
        let bubbleWidth = row.kind == .userMessage ? min(width * 0.72, 620) : width - indent
        let bounding = attributed.boundingRect(
            with: NSSize(width: bubbleWidth - 20, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // Text, plus the bubble's own padding (16), plus the cell's vertical
        // inset — and the badge line only when there is a badge to show.
        let badgeLine: CGFloat = badgeText(for: row).isEmpty ? 0 : 14
        return ceil(bounding.height) + 16 + verticalInset * 2 + badgeLine
    }

    /// The row's rendered content.
    ///
    /// Agent prose is markdown — headings, lists, inline code, fenced blocks —
    /// and showing it raw makes the reader parse formatting by eye in the one
    /// place they are trying to read quickly. Measuring and drawing both go
    /// through here so a row's cached height always matches what it draws.
    static func attributedText(for row: TranscriptRow) -> NSAttributedString {
        if let cached = renderCache.value(for: row) { return cached }

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
            ).render(row.text)

        case .toolCall, .thinking, .error:
            rendered = processText(for: row)

        case .activityGroup:
            rendered = activityGroupText(for: row)

        case .userMessage, .divider:
            rendered = NSAttributedString(
                string: displayText(for: row),
                attributes: [.font: font(for: row), .foregroundColor: textColor(for: row)]
            )
        }

        renderCache.store(rendered, for: row)
        return rendered
    }

    /// Markdown parsing is not free, and a streaming row is re-measured and
    /// redrawn on every delta. Caching by (id, text length, completeness) keeps
    /// that to one parse per change rather than several.
    private nonisolated(unsafe) static var renderCache = RenderCache()

    struct RenderCache {
        private var entries: [String: (signature: Int, value: NSAttributedString)] = [:]

        private func signature(for row: TranscriptRow) -> Int {
            var hasher = Hasher()
            hasher.combine(row.text)
            hasher.combine(row.resultText)
            hasher.combine(row.isComplete)
            hasher.combine(row.isExpanded)
            hasher.combine(row.toolInput)
            hasher.combine(row.resultMetadata)
            hasher.combine(row.activitySignature)
            return hasher.finalize()
        }

        func value(for row: TranscriptRow) -> NSAttributedString? {
            guard let entry = entries[row.id], entry.signature == signature(for: row)
            else { return nil }
            return entry.value
        }

        mutating func store(_ value: NSAttributedString, for row: TranscriptRow) {
            if entries.count > 2000 { entries.removeAll(keepingCapacity: true) }
            entries[row.id] = (signature(for: row), value)
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

    private static func badgeText(for row: TranscriptRow) -> String {
        switch row.kind {
        // The visual treatment already says who is talking — a tinted block for
        // the user, plain prose for the agent — so "YOU"/"AGENT" on every row
        // was noise. Badges remain only where they carry something the styling
        // can't: which tool ran, and error / plan callouts.
        case .userMessage, .assistantText, .thinking, .divider, .activityGroup, .toolCall, .error:
            return ""
        case .plan:
            return "PLAN"
        }
    }

    private static func font(for row: TranscriptRow) -> NSFont {
        switch row.kind {
        case .toolCall:
            return .monospacedSystemFont(ofSize: 12, weight: .regular)
        case .activityGroup:
            return .systemFont(ofSize: 12, weight: .regular)
        case .thinking:
            return .systemFont(ofSize: 13)
        case .divider:
            return .systemFont(ofSize: 11, weight: .medium)
        case .assistantText, .plan:
            return .systemFont(ofSize: 15)
        default:
            return .systemFont(ofSize: 14)
        }
    }

    private static func textColor(for row: TranscriptRow) -> NSColor {
        switch row.kind {
        case .thinking, .divider, .activityGroup: return .secondaryLabelColor
        case .error: return .systemRed
        default: return .labelColor
        }
    }

    private static func background(for row: TranscriptRow) -> NSColor {
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

    /// A small rounded, outlined pill for a file reference or command argument,
    /// drawn as an image so it can sit inline in the attributed transcript text.
    /// This is the quiet "chip" look — subtle fill, hairline border, an optional
    /// language icon, then the label — instead of a flat highlight or a
    /// full-width band.
    private static func subjectPillImage(
        identity: FileVisualIdentity?,
        text: String,
        monospace: Bool
    ) -> NSImage {
        let font = monospace
            ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            : NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]
        let textSize = (text as NSString).size(withAttributes: textAttrs)
        let iconSize: CGFloat = identity != nil ? 13 : 0
        let iconGap: CGFloat = identity != nil ? 5 : 0
        let hPad: CGFloat = 7
        let vPad: CGFloat = 3
        let width = ceil(hPad + iconSize + iconGap + textSize.width + hPad)
        let height = ceil(textSize.height + vPad * 2)
        let image = NSImage(size: NSSize(width: max(1, width), height: max(1, height)))
        image.lockFocus()
        let rect = NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1)
        let radius = height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.secondaryLabelColor.withAlphaComponent(0.09).setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        path.stroke()
        var x = hPad
        if let identity {
            let icon = identity.appKitImage(size: iconSize)
            icon.draw(in: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
            x += iconSize + iconGap
        }
        (text as NSString).draw(
            at: NSPoint(x: x, y: (height - textSize.height) / 2),
            withAttributes: textAttrs
        )
        image.unlockFocus()
        return image
    }

    private static func processText(for row: TranscriptRow) -> NSAttributedString {
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
                monospace: item.fileIdentity == nil
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
            if let path = item.filePath,
               let url = MarkdownRenderer.fileReferenceURL(path) {
                result.addAttribute(
                    .link,
                    value: url,
                    range: NSRange(location: subjectStart, length: result.length - subjectStart)
                )
            }
        }
        if item.insertions > 0 {
            result.append(NSAttributedString(
                string: "   +\(item.insertions)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemGreen]
            ))
        }
        if item.deletions > 0 {
            result.append(NSAttributedString(
                string: "  −\(item.deletions)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemRed]
            ))
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
            else if item.isDiff && value.hasPrefix("-") && !value.hasPrefix("---") { color = .systemRed }
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

        // The files this turn changed, as small pills — what actually landed,
        // once the agent has finished.
        let changed = changedFiles(in: row.groupedRows)
        if !changed.isEmpty {
            result.append(NSAttributedString(string: "\n", attributes: secondary))
            for file in changed.prefix(8) {
                result.append(NSAttributedString(string: "  "))
                let pill = subjectPillImage(
                    identity: FileVisualIdentity(path: file.path),
                    text: (file.path as NSString).lastPathComponent,
                    monospace: false
                )
                let attachment = NSTextAttachment()
                attachment.image = pill
                attachment.bounds = NSRect(x: 0, y: -5, width: pill.size.width, height: pill.size.height)
                result.append(NSAttributedString(attachment: attachment))
                if file.insertions > 0 {
                    result.append(NSAttributedString(string: " +\(file.insertions)", attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: NSColor.systemGreen,
                    ]))
                }
                if file.deletions > 0 {
                    result.append(NSAttributedString(string: " −\(file.deletions)", attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: NSColor.systemRed,
                    ]))
                }
            }
            if changed.count > 8 {
                result.append(NSAttributedString(string: "  +\(changed.count - 8) more", attributes: secondary))
            }
        }
        return result
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
                tint: .controlAccentColor
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
            let suppliedDiff = patchText ?? input?[0]?["diff"]?.stringValue
            let old = input?["old_string"]?.stringValue
            let new = input?["new_string"]?.stringValue
            let diff = suppliedDiff ?? [old.map { "− " + $0 }, new.map { "+ " + $0 }]
                .compactMap { $0 }.joined(separator: "\n")
            let changeKind = input?[0]?["kind"]?["type"]?.stringValue
                ?? input?["kind"]?["type"]?.stringValue
            var plus = diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            var minus = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            if plus == 0, minus == 0, changeKind == "add" {
                plus = diff.split(separator: "\n", omittingEmptySubsequences: true).count
            } else if plus == 0, minus == 0, changeKind == "delete" {
                minus = diff.split(separator: "\n", omittingEmptySubsequences: true).count
            }
            let isWrite = key.contains("write") || changeKind == "add"
            return ProcessPresentation(
                icon: isWrite ? "doc.badge.plus" : "pencil.line",
                title: isWrite ? "Write" : "Edit",
                detail: diff.isEmpty ? resultText : diff, tint: row.isError ? .systemRed : .labelColor,
                fileIdentity: path.map { FileVisualIdentity(path: $0) },
                subject: patchPaths.count > 1 ? "\(patchPaths.count) files" : fileName ?? compact(row.text),
                filePath: patchPaths.count <= 1 ? path : nil,
                insertions: plus, deletions: minus, isDiff: true
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
                    tint: .secondaryLabelColor,
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
                    tint: .secondaryLabelColor,
                    fileIdentity: FileVisualIdentity(path: commandPath),
                    subject: commandFileName,
                    filePath: commandPath
                )
            }
            if looksLikeSearch {
                return ProcessPresentation(
                    icon: "magnifyingglass", title: "Search",
                    detail: resultText.isEmpty ? command : resultText,
                    tint: .secondaryLabelColor,
                    subject: compact(command.split(separator: "\n").first.map(String.init) ?? command)
                )
            }
            let summary = compact(command.split(separator: "\n").first.map(String.init) ?? command)
            return ProcessPresentation(icon: "terminal", title: "Bash", detail: resultText.isEmpty ? command : resultText, tint: row.isError ? .systemRed : .labelColor, subject: summary)
        }
        if key.contains("image") || ["png", "jpg", "jpeg", "gif", "webp"].contains((path as NSString?)?.pathExtension.lowercased() ?? "") {
            return ProcessPresentation(icon: "photo", title: "Read image", detail: path ?? resultText, tint: .secondaryLabelColor, fileIdentity: path.map { FileVisualIdentity(path: $0) }, subject: fileName, filePath: path)
        }
        if key.contains("read") || key.contains("file") {
            let lineCount = resultText.isEmpty ? input?["limit"]?.intValue : resultText.split(separator: "\n").count
            let count = lineCount.map { "\($0) lines " } ?? ""
            return ProcessPresentation(icon: "doc.text", title: "Read \(count)".trimmingCharacters(in: .whitespaces), detail: resultText.isEmpty ? (path ?? row.text) : resultText, tint: .secondaryLabelColor, fileIdentity: path.map { FileVisualIdentity(path: $0) }, subject: fileName ?? compact(row.text), filePath: path)
        }
        if key.contains("web") || key.contains("fetch") || input?["url"]?.stringValue != nil {
            let url = input?["url"]?.stringValue ?? input?["query"]?.stringValue ?? row.text
            return ProcessPresentation(icon: "globe", title: "Fetch", detail: resultText, tint: .secondaryLabelColor, subject: compact(url))
        }
        if key.contains("search") || key.contains("grep") || key.contains("glob") {
            let query = input?["query"]?.stringValue ?? input?["q"]?.stringValue ?? input?["pattern"]?.stringValue ?? row.text
            return ProcessPresentation(icon: "magnifyingglass", title: "Search", detail: resultText, tint: .secondaryLabelColor, subject: compact(query))
        }
        return ProcessPresentation(icon: "gearshape", title: row.text, detail: resultText, tint: row.isError ? .systemRed : .secondaryLabelColor)
    }

    private static func meaningful(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !value.isEmpty && !["null", "nil", "<null>", "(null)", "\"null\""].contains(value)
    }

    private static func compact(_ text: String, limit: Int = 110) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
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

/// The transcript's text view: read-only and selectable, but it also carries
/// the row's click gestures, so tapping the text still toggles an activity
/// group (single click) or reverts to a checkpoint (double click) exactly as
/// the enclosing cell used to. Without this, making the text selectable would
/// have swallowed those clicks into a text selection.
private final class TranscriptTextView: NSTextView, NSTextViewDelegate {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onOpenFile: ((String) -> Void)?

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
