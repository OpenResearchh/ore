import AppKit

/// A deliberately bounded Mermaid flowchart reader. Unknown syntax falls back
/// to the original code block rather than silently drawing a different graph.
struct Flowchart {
    struct Node {
        var id: String
        var label: String
        var shape: String
        var parent: String? = nil
    }
    struct Edge {
        var from: String
        var to: String
        var label: String
    }
    struct Group {
        var id: String
        var label: String
        var parent: String?
        var direction: String
    }
    var groups: [Group] = []
    var direction: String
    var nodes: [Node]
    var edges: [Edge]

    static func parse(_ source: String) -> Flowchart? {
        guard source.utf8.count <= 32_768 else { return nil }
        var reader = Reader(text: source[...])
        guard let kind = reader.word(), ["flowchart", "graph"].contains(kind),
              let direction = reader.word(), ["TD", "TB", "BT", "LR", "RL"].contains(direction)
        else { return nil }
        var graph = Flowchart(direction: direction, nodes: [], edges: [])
        var groupStack: [String] = []
        func insert(_ value: Node) {
            guard !graph.groups.contains(where: { $0.id == value.id }) else { return }
            var node = value
            node.parent = groupStack.last
            if let index = graph.nodes.firstIndex(where: { $0.id == node.id }) {
                if !node.shape.isEmpty {
                    node.parent = graph.nodes[index].parent
                    graph.nodes[index] = node
                }
            } else { graph.nodes.append(node) }
        }
        while !reader.text.isEmpty {
            reader.space()
            if reader.consume(";") { continue }
            if reader.consume("%%") {
                reader.text = reader.text.drop(while: { $0 != "\n" })
                continue
            }
            if reader.text.isEmpty { break }
            var probe = reader
            let keyword = probe.word()
            if keyword == "subgraph" {
                let header = probe.text.prefix(while: { $0 != "\n" && $0 != ";" }).trimmingCharacters(in: .whitespaces)
                var headerReader = Reader(text: header[...])
                guard let groupNode = headerReader.node(), headerReader.text.trimmingCharacters(in: .whitespaces).isEmpty,
                      !graph.groups.contains(where: { $0.id == groupNode.id }), graph.groups.count < 12 else { return nil }
                graph.groups.append(Group(id: groupNode.id, label: groupNode.label, parent: groupStack.last,
                                          direction: groupStack.last.flatMap { parent in graph.groups.first { $0.id == parent }?.direction } ?? direction))
                graph.nodes.removeAll { $0.id == groupNode.id }
                groupStack.append(groupNode.id)
                probe.text = probe.text.drop(while: { $0 != "\n" && $0 != ";" })
                reader = probe
                continue
            }
            if keyword == "end" {
                guard !groupStack.isEmpty else { return nil }
                groupStack.removeLast()
                reader = probe
                continue
            }
            if keyword == "direction" {
                guard let parent = groupStack.last, let value = probe.word(),
                      ["TD", "TB", "BT", "LR", "RL"].contains(value),
                      let index = graph.groups.firstIndex(where: { $0.id == parent }) else { return nil }
                graph.groups[index].direction = value
                reader = probe
                continue
            }
            guard var node = reader.node() else { return nil }
            insert(node)
            while true {
                reader.space()
                guard reader.consume("-->") else { break }
                reader.space()
                var label = ""
                if reader.consume("|") {
                    guard let end = reader.text.firstIndex(of: "|") else { return nil }
                    label = String(reader.text[..<end])
                    reader.text = reader.text[reader.text.index(after: end)...]
                }
                guard let next = reader.node() else { return nil }
                insert(next)
                graph.edges.append(Edge(from: node.id, to: next.id, label: clean(label)))
                node = next
            }
            guard graph.nodes.count <= 60, graph.edges.count <= 120 else { return nil }
        }
        return graph.nodes.isEmpty || !groupStack.isEmpty ? nil : graph
    }

    private static func clean(_ label: String) -> String {
        var result = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("\""), result.hasSuffix("\"") { result = String(result.dropFirst().dropLast()) }
        for tag in ["<br/>", "<br />", "<br>"] { result = result.replacingOccurrences(of: tag, with: "\n") }
        return result
    }

    private struct Reader {
        var text: Substring
        mutating func space() { text = text.drop(while: { $0.isWhitespace }) }
        mutating func consume(_ value: String) -> Bool {
            guard text.hasPrefix(value) else { return false }
            text = text.dropFirst(value.count)
            return true
        }
        mutating func word() -> String? {
            space()
            let value = text.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            guard !value.isEmpty else { return nil }
            text = text.dropFirst(value.count)
            return String(value)
        }
        mutating func node() -> Node? {
            guard let id = word(), !["subgraph", "end", "style", "classDef", "class", "direction", "linkStyle"].contains(id)
            else { return nil }
            space()
            let shapes = [("((", "))"), ("[", "]"), ("(", ")"), ("{", "}")]
            for (open, close) in shapes where text.hasPrefix(open) {
                _ = consume(open)
                var quoted = false
                var label = ""
                while !text.isEmpty {
                    if !quoted, consume(close) {
                        guard label.count <= 500 else { return nil }
                        return Node(id: id, label: Flowchart.clean(label), shape: open)
                    }
                    let char = text.removeFirst()
                    if char == "\"" { quoted.toggle() }
                    // Nested shapes belong to Mermaid forms we do not implement.
                    if !quoted, "[]{}()".contains(char) { return nil }
                    label.append(char)
                }
                return nil
            }
            return Node(id: id, label: id, shape: "")
        }
    }

    struct Layout {
        var size: NSSize
        var positions: [String: NSRect]
    }

    /// Lay out each group as its own graph, then place its bounding box in its
    /// parent's graph. Group members never become interleaved with siblings.
    func layout(nodeSize: NSSize) -> Layout {
        let parents = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parent) } + groups.map { ($0.id, $0.parent) })
        func child(of parent: String?, containing id: String) -> String? {
            var current = id
            for _ in 0...groups.count {
                guard let entry = parents[current] else { return nil }
                if entry == parent { return current }
                guard let next = entry else { return nil }
                current = next
            }
            return nil
        }
        func arrange(parent: String?, direction: String) -> Layout {
            let horizontal = direction == "LR" || direction == "RL"
            let reversed = direction == "BT" || direction == "RL"
            let members = nodes.filter { $0.parent == parent }.map(\.id) + groups.filter { $0.parent == parent }.map(\.id)
            var contents: [String: Layout] = [:]
            for id in members {
                if let group = groups.first(where: { $0.id == id }) {
                    contents[id] = arrange(parent: id, direction: group.direction)
                } else { contents[id] = Layout(size: nodeSize, positions: [:]) }
            }
            let links = edges.compactMap { edge -> (String, String)? in
                guard let from = child(of: parent, containing: edge.from),
                      let to = child(of: parent, containing: edge.to), from != to else { return nil }
                return (from, to)
            }
            var ranks: [String: Int] = [:]
            func visit(_ id: String, rank: Int) {
                guard ranks[id] == nil else { return }
                ranks[id] = rank
                for link in links where link.0 == id { visit(link.1, rank: rank + 1) }
            }
            let incoming = Set(links.map { $0.1 })
            for id in members where !incoming.contains(id) { visit(id, rank: 0) }
            for id in members { visit(id, rank: 0) }
            let layers = (0...(ranks.values.max() ?? 0)).map { rank in members.filter { ranks[$0] == rank } }
            let mainSizes = layers.map { layer in layer.map { horizontal ? contents[$0]!.size.width : contents[$0]!.size.height }.max() ?? 0 }
            let crossSizes = layers.map { layer in layer.reduce(CGFloat(0)) { sum, id in sum + (horizontal ? contents[id]!.size.height : contents[id]!.size.width) } + CGFloat(max(0, layer.count - 1)) * 70 }
            let mainSize = mainSizes.reduce(0, +) + CGFloat(max(0, layers.count - 1)) * 100
            let crossSize = crossSizes.max() ?? 0
            let padding: CGFloat = 80
            let titleHeight: CGFloat = parent == nil ? 0 : 36
            let size = NSSize(width: (horizontal ? mainSize : crossSize) + padding * 2,
                              height: (horizontal ? crossSize : mainSize) + padding * 2 + titleHeight)
            var positions: [String: NSRect] = [:]
            var main: CGFloat = 0
            for (index, layer) in layers.enumerated() {
                var cross = (crossSize - crossSizes[index]) / 2
                for id in layer {
                    let content = contents[id]!
                    let extent = horizontal ? content.size.width : content.size.height
                    let along = reversed ? mainSize - main - extent : main
                    let origin = NSPoint(x: padding + (horizontal ? along : cross), y: padding + titleHeight + (horizontal ? cross : along))
                    positions[id] = NSRect(origin: origin, size: content.size)
                    for (nested, rect) in content.positions { positions[nested] = rect.offsetBy(dx: origin.x, dy: origin.y) }
                    cross += (horizontal ? content.size.height : content.size.width) + 70
                }
                main += mainSizes[index] + 100
            }
            return Layout(size: size, positions: positions)
        }
        return arrange(parent: nil, direction: direction)
    }

    func image(font: NSFont, textColor: NSColor) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: max(12, font.pointSize))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: textColor, .paragraphStyle: paragraph,
        ]
        let nodeWidth: CGFloat = 220
        let tallest = nodes.map {
            ($0.label as NSString).boundingRect(
                with: NSSize(width: nodeWidth - 70, height: 2000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
            ).height
        }.max() ?? 20
        let nodeHeight = max(76, ceil(tallest) * 2 + 24)
        let layout = layout(nodeSize: NSSize(width: nodeWidth, height: nodeHeight))
        let size = layout.size
        let positions = layout.positions
        return NSImage(size: size, flipped: true) { _ in
            for group in groups {
                guard let rect = positions[group.id] else { continue }
                let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
                NSColor.controlAccentColor.withAlphaComponent(0.035).setFill()
                path.fill()
                NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
                path.lineWidth = 1
                path.stroke()
                (group.label as NSString).draw(in: NSRect(x: rect.minX + 16, y: rect.minY + 16, width: rect.width - 32, height: 40), withAttributes: attributes)
            }
            NSColor.secondaryLabelColor.setStroke()
            for (index, edge) in edges.enumerated() {
                guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                let fromParent = nodes.first { $0.id == edge.from }?.parent ?? groups.first { $0.id == edge.from }?.parent
                let toParent = nodes.first { $0.id == edge.to }?.parent ?? groups.first { $0.id == edge.to }?.parent
                let commonParent = fromParent == toParent ? fromParent : nil
                let localDirection = commonParent.flatMap { parent in groups.first { $0.id == parent }?.direction } ?? direction
                let horizontal = localDirection == "LR" || localDirection == "RL"
                let positive = horizontal ? to.midX > from.midX : to.midY > from.midY
                let reversed = localDirection == "BT" || localDirection == "RL"
                let separated = horizontal ? abs(to.midX - from.midX) > from.width / 2 + to.width / 2 : abs(to.midY - from.midY) > from.height / 2 + to.height / 2
                let forward = separated && positive != reversed
                let start = horizontal
                    ? NSPoint(x: positive ? from.maxX : from.minX, y: from.midY)
                    : NSPoint(x: from.midX, y: positive ? from.maxY : from.minY)
                let end = horizontal
                    ? NSPoint(x: positive ? to.minX : to.maxX, y: to.midY)
                    : NSPoint(x: to.midX, y: positive ? to.minY : to.maxY)
                let path = NSBezierPath()
                path.move(to: start)
                var previous = start
                var labelCenter = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                if forward {
                    let middle = horizontal ? (start.x + end.x) / 2 : (start.y + end.y) / 2
                    path.line(to: horizontal ? NSPoint(x: middle, y: start.y) : NSPoint(x: start.x, y: middle))
                    previous = horizontal ? NSPoint(x: middle, y: end.y) : NSPoint(x: end.x, y: middle)
                    path.line(to: previous)
                } else {
                    // Return edges run outside the nodes, including self loops.
                    let lane = CGFloat(12 + index % 5 * 6)
                    let outside = horizontal ? max(from.maxY, to.maxY) + lane : max(from.maxX, to.maxX) + lane
                    labelCenter = horizontal
                        ? NSPoint(x: (start.x + end.x) / 2, y: outside)
                        : NSPoint(x: outside, y: (start.y + end.y) / 2)
                    let offset: CGFloat = positive ? 20 : -20
                    let a = horizontal ? NSPoint(x: start.x + offset, y: start.y) : NSPoint(x: start.x, y: start.y + offset)
                    let b = horizontal ? NSPoint(x: end.x - offset, y: end.y) : NSPoint(x: end.x, y: end.y - offset)
                    path.line(to: a)
                    path.line(to: horizontal ? NSPoint(x: a.x, y: outside) : NSPoint(x: outside, y: a.y))
                    path.line(to: horizontal ? NSPoint(x: b.x, y: outside) : NSPoint(x: outside, y: b.y))
                    path.line(to: b)
                    previous = b
                }
                path.line(to: end)
                path.lineWidth = 1.5
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
                let angle = atan2(end.y - previous.y, end.x - previous.x)
                let arrow = NSBezierPath()
                arrow.move(to: end)
                for delta in [-0.45, 0.45] {
                    arrow.line(to: NSPoint(x: end.x - 9 * cos(angle + delta), y: end.y - 9 * sin(angle + delta)))
                    arrow.move(to: end)
                }
                arrow.stroke()
                if !edge.label.isEmpty {
                    let rect = NSRect(x: labelCenter.x - 65, y: labelCenter.y - 12, width: 130, height: 30)
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                    (edge.label as NSString).draw(in: rect.insetBy(dx: 3, dy: 3), withAttributes: attributes)
                }
            }
            for node in nodes {
                guard let rect = positions[node.id] else { continue }
                let path: NSBezierPath
                if node.shape == "{" {
                    path = NSBezierPath()
                    path.move(to: NSPoint(x: rect.midX, y: rect.minY))
                    path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                    path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
                    path.line(to: NSPoint(x: rect.minX, y: rect.midY))
                    path.close()
                } else if node.shape == "((" {
                    path = NSBezierPath(ovalIn: rect)
                } else {
                    path = NSBezierPath(roundedRect: rect, xRadius: node.shape == "(" ? 22 : 7, yRadius: node.shape == "(" ? 22 : 7)
                }
                NSColor.windowBackgroundColor.setFill()
                path.fill()
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                path.fill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5
                path.stroke()
                let bounds = (node.label as NSString).boundingRect(with: NSSize(width: nodeWidth - 70, height: nodeHeight), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
                (node.label as NSString).draw(in: NSRect(x: rect.minX + 35, y: rect.midY - bounds.height / 2, width: nodeWidth - 70, height: ceil(bounds.height)), withAttributes: attributes)
            }
            return true
        }
    }
}

/// TextKit asks for the available line width both during row measurement and
/// drawing, so the same diagram fits the transcript, HUD and document preview.
final class FlowchartAttachment: NSTextAttachment {
    var originalImage: NSImage?
    var viewport = FlowchartViewport()

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let image else { return .zero }
        let available = max(1, lineFrag.width - 2 * (textContainer?.lineFragmentPadding ?? 0))
        let scale = min(1, available / image.size.width)
        return NSRect(origin: .zero, size: NSSize(width: image.size.width * scale, height: image.size.height * scale))
    }
}
