import AppKit
import Testing
@testable import OreMac

struct FlowchartTests {
    @Test func branchingAndReturnEdges() throws {
        let chart = try #require(Flowchart.parse("""
            flowchart TD
              mic["Hold-to-talk speech"] --> debounce["Wait 250ms, or ask now if you hit . ? ! and/then"]
              debounce --> leftover["Leftover text only<br/>not the whole ramble"]
              leftover --> click{"Click a pane?"}
              click -->|yes| ui["Move sidebar / review / terminal"]
              click -->|yes| next["Keep the next clause"]
              next --> leftover
            """))
        #expect(chart.nodes.count == 6)
        #expect(chart.edges.count == 6)
        #expect(chart.nodes[2].label == "Leftover text only\nnot the whole ramble")
        #expect(chart.nodes[3].shape == "{")
        #expect(chart.edges[3].label == "yes")
    }

    static let grouped = """
        flowchart LR
          subgraph give ["What we give Laya"]
            msg["state.message<br/>e.g. shut the left side bar close the terminal"]
            q1["is_chrome · noul<br/>yes/no: is this a pane command?"]
            q2["action · choice<br/>which control, or none"]
            q3["has_work · noul<br/>yes/no: leftover coding work?"]
          end
          subgraph get ["What Laya returns"]
            a1["is_chrome.noul  0–1"]
            a2["action.choice + probabilities"]
            a3["has_work.noul  0–1"]
          end
          give --> laya["Laya BERT"] --> get
        """

    @Test func screenshotGroupsAreLabeledAndContained() throws {
        let chart = try #require(Flowchart.parse(Self.grouped))
        #expect(chart.groups.map(\.label) == ["What we give Laya", "What Laya returns"])
        #expect(chart.nodes.count == 8)
        #expect(!chart.nodes.contains { $0.id == "give" || $0.id == "get" })
        let layout = chart.layout(nodeSize: NSSize(width: 220, height: 100))
        let give = try #require(layout.positions["give"])
        let get = try #require(layout.positions["get"])
        #expect(!give.intersects(get))
        #expect(give.maxX < get.minX)
        for node in chart.nodes {
            if let parent = node.parent {
                let groupRect = try #require(layout.positions[parent])
                let nodeRect = try #require(layout.positions[node.id])
                #expect(groupRect.contains(nodeRect))
            }
        }
        let image = chart.image(font: .systemFont(ofSize: 13), textColor: .labelColor)
        #expect(image.tiffRepresentation != nil)
        if let directory = ProcessInfo.processInfo.environment["ORE_FLOWCHART_PREVIEWS"],
           let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("groups.png"))
        }
    }

    @Test func nestedGroupsAndLocalDirections() throws {
        let chart = try #require(Flowchart.parse("flowchart LR\nsubgraph outer[Outer]\ndirection TB\nsubgraph inner[Inner]\nA --> B\nend\ninner --> C\nend"))
        #expect(chart.groups[1].parent == "outer")
        #expect(chart.groups[1].direction == "TB")
        let layout = chart.layout(nodeSize: NSSize(width: 220, height: 100))
        let outer = try #require(layout.positions["outer"])
        let inner = try #require(layout.positions["inner"])
        let a = try #require(layout.positions["A"])
        let b = try #require(layout.positions["B"])
        #expect(outer.contains(inner))
        #expect(inner.contains(a))
        #expect(a.maxY < b.minY)
        #expect(Flowchart.parse("flowchart LR\nend") == nil)
    }

    @Test @MainActor func zoomChangesOnlyTheHitDiagramInOneView() throws {
        let rendered = MarkdownRenderer().render("Before\n\n```mermaid\nflowchart TD\nA --> B\n```\n\nMiddle\n\n```mermaid\nflowchart LR\nC --> D\n```\n\nAfter")
        func makeView() -> FlowchartTextView {
            let view = FlowchartTextView(usingTextLayoutManager: false)
            view.frame = NSRect(x: 0, y: 0, width: 500, height: 2000)
            view.textContainerInset = .zero
            view.textContainer?.containerSize = NSSize(width: 500, height: 10000)
            view.textStorage?.setAttributedString(rendered)
            return view
        }
        let view = makeView()
        let other = makeView()
        let storage = try #require(view.textStorage)
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height
        var indices: [Int] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value is FlowchartAttachment { indices.append(range.location) }
        }
        #expect(indices.count == 2)
        let index = indices[0]
        let original = try #require(storage.attribute(.attachment, at: index, effectiveRange: nil) as? FlowchartAttachment)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        #expect(view.zoomDiagram(at: NSPoint(x: rect.midX, y: rect.midY), magnification: 1))
        let zoomed = try #require(storage.attribute(.attachment, at: index, effectiveRange: nil) as? FlowchartAttachment)
        #expect(zoomed !== original)
        #expect(zoomed.viewport.scale == 2)
        #expect(original.viewport.scale == 1)
        #expect(zoomed.image?.size == original.image?.size)
        #expect(zoomed.image?.tiffRepresentation != nil)
        if let directory = ProcessInfo.processInfo.environment["ORE_FLOWCHART_PREVIEWS"] {
            for (name, image) in [("before", original.image), ("zoomed", zoomed.image)] {
                if let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
                }
            }
        }
        #expect(other.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? FlowchartAttachment === original)
        let second = try #require(storage.attribute(.attachment, at: indices[1], effectiveRange: nil) as? FlowchartAttachment)
        #expect(second.viewport.scale == 1)
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).height == height)
        #expect(storage.string == rendered.string)
        #expect(!view.zoomDiagram(at: NSPoint(x: 5, y: 5), magnification: 1))
    }

    @Test func viewportPreservesAnchorAndClampsZoomAndPan() {
        var viewport = FlowchartViewport()
        viewport.magnify(by: 1, anchor: NSPoint(x: 0.25, y: 0.75))
        #expect(viewport.scale == 2)
        #expect(viewport.origin == NSPoint(x: 0.125, y: 0.375))
        viewport.pan(by: NSPoint(x: -100, y: 100))
        #expect(viewport.origin == NSPoint(x: 0.5, y: 0))
        viewport.magnify(by: 100, anchor: .zero)
        #expect(viewport.scale == 8)
        viewport.magnify(by: -1, anchor: .zero)
        #expect(viewport.scale == 1)
        #expect(viewport.origin == .zero)
    }

    @Test func declarationsChainsAndComments() throws {
        let chart = try #require(Flowchart.parse("graph LR; A --> B --> C; %% comment\nB(Updated); C((Done))"))
        #expect(chart.nodes.count == 3)
        #expect(chart.edges.count == 2)
        #expect(chart.nodes[1].label == "Updated")
        #expect(chart.nodes[2].shape == "((")
    }

    @Test func incompleteAndUnsupportedSyntaxFallsBack() {
        for source in ["flowchart TD\nA -->", "flowchart TD\nA[\"unfinished", "sequenceDiagram\nA->>B: Hi", "flowchart TD\nsubgraph x\nA --> B", "flowchart TD\nA -.-> B", "flowchart TD\nA[[Subroutine]]"] {
            #expect(Flowchart.parse(source) == nil, "\(source)")
        }
    }

    @Test func rendererUsesAttachmentsOnlyForFlowcharts() {
        let renderer = MarkdownRenderer()
        for language in ["mermaid", "", "MERMAID"] {
            let rendered = renderer.render("Before\n\n```\(language)\nflowchart TD\nA --> B\n```\n\nAfter")
            var found = false
            rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                if value is FlowchartAttachment { found = true }
            }
            #expect(found)
            #expect(rendered.string.contains("Before"))
            #expect(rendered.string.contains("After"))
        }
        #expect(renderer.render("```swift\nflowchart TD\nA --> B\n```").string.contains("A --> B"))
        #expect(renderer.render("```mermaid\nflowchart TD\nA -->\n```").string.contains("A -->"))
    }

    @Test @MainActor func textKitMeasuresTheScaledDiagram() throws {
        let rendered = MarkdownRenderer().render("```mermaid\nflowchart TD\nA[Start] --> B{Ready?}\nB -->|yes| C(Done)\nB -->|no| A\n```")
        let attachment = try #require(rendered.attribute(.attachment, at: 0, effectiveRange: nil) as? FlowchartAttachment)
        let image = try #require(attachment.image)
        let height = TranscriptHeightMeasurer.height(of: rendered, width: 300)
        #expect(height >= 300 * image.size.height / image.size.width)
        #expect(height < 300 * image.size.height / image.size.width + 40)
    }

    @Test func diagramDrawsOffMain() async throws {
        let pixels = try await Task.detached {
            let chart = try #require(Flowchart.parse("flowchart TD\nA[Start] --> B{Ready?}\nB -->|yes| C(Done)\nB -->|no| A"))
            let image = chart.image(font: .systemFont(ofSize: 13), textColor: .labelColor)
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            return bitmap.pixelsWide * bitmap.pixelsHigh
        }.value
        #expect(pixels > 0)
    }

    @Test func resizingPreservesAspectRatioAndCyclesTerminate() throws {
        for direction in ["TD", "TB", "BT", "LR", "RL"] {
            let chart = try #require(Flowchart.parse("flowchart \(direction)\nA --> B --> A\nA --> A"))
            let attachment = FlowchartAttachment()
            attachment.image = chart.image(font: .systemFont(ofSize: 13), textColor: .labelColor)
            let size = try #require(attachment.image).size
            let bounds = attachment.attachmentBounds(for: nil, proposedLineFragment: NSRect(x: 0, y: 0, width: 180, height: 20), glyphPosition: .zero, characterIndex: 0)
            #expect(bounds.width <= 180)
            #expect(abs(bounds.height / bounds.width - size.height / size.width) < 0.001)
        }
    }
}
