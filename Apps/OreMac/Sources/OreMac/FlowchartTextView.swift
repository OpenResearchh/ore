import AppKit

/// A viewport in normalized diagram coordinates. Its size in the transcript
/// never changes, so zoom cannot resize prose or invalidate row-height caches.
struct FlowchartViewport {
    var scale: CGFloat = 1
    var origin = NSPoint.zero

    mutating func magnify(by amount: CGFloat, anchor: NSPoint) {
        guard amount.isFinite else { return }
        let next = min(8, max(1, scale * (1 + amount)))
        origin.x += anchor.x / scale - anchor.x / next
        origin.y += anchor.y / scale - anchor.y / next
        scale = next
        clamp()
    }

    mutating func pan(by delta: NSPoint) {
        origin.x -= delta.x / scale
        origin.y -= delta.y / scale
        clamp()
    }

    private mutating func clamp() {
        let limit = 1 - 1 / scale
        origin.x = min(limit, max(0, origin.x))
        origin.y = min(limit, max(0, origin.y))
    }
}

/// Shared by the transcript (including the HUD) and Markdown file previews.
/// Copy an attachment before interacting: the render cache, measurement stack,
/// and another window may all hold the original attributed string.
class FlowchartTextView: NSTextView {
    private var pinchTarget: (index: Int, attachment: FlowchartAttachment)?

    struct DiagramHit {
        var index: Int
        var attachment: FlowchartAttachment
        var rect: NSRect
    }

    func diagram(at point: NSPoint) -> DiagramHit? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length,
              let attachment = textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? FlowchartAttachment else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(local) else { return nil }
        return DiagramHit(index: index, attachment: attachment,
                          rect: rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
    }

    @discardableResult
    func zoomDiagram(at point: NSPoint, magnification: CGFloat) -> Bool {
        guard let hit = diagram(at: point), hit.rect.width > 0, hit.rect.height > 0 else { return false }
        let attachment = hit.attachment.interactiveCopy()
        attachment.viewport.magnify(by: magnification, anchor: NSPoint(
            x: (point.x - hit.rect.minX) / hit.rect.width,
            y: (point.y - hit.rect.minY) / hit.rect.height
        ))
        install(attachment, at: hit.index)
        pinchTarget = (hit.index, attachment)
        return true
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.phase == .began { pinchTarget = nil }
        defer {
            if event.phase == .ended || event.phase == .cancelled { pinchTarget = nil }
        }
        if let target = pinchTarget {
            // A row may be reused or re-rendered between gesture events.
            guard let storage = textStorage, target.index < storage.length,
                  storage.attribute(.attachment, at: target.index, effectiveRange: nil) as? FlowchartAttachment === target.attachment,
                  let hit = diagram(at: point), hit.index == target.index else { return }
        } else if event.phase != .began && event.phase != [] { return }
        _ = zoomDiagram(at: point, magnification: event.magnification)
        // Do not forward to NSTextView's text magnification or a parent scroll
        // view. A pinch outside a diagram leaves the transcript unchanged.
    }

    override func smartMagnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = diagram(at: point) else { return }
        let attachment = hit.attachment.interactiveCopy()
        attachment.viewport = FlowchartViewport()
        install(attachment, at: hit.index)
        pinchTarget = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = diagram(at: point), hit.attachment.viewport.scale > 1 else {
            super.scrollWheel(with: event)
            return
        }
        let attachment = hit.attachment.interactiveCopy()
        attachment.viewport.pan(by: NSPoint(x: event.scrollingDeltaX / hit.rect.width,
                                          y: event.scrollingDeltaY / hit.rect.height))
        install(attachment, at: hit.index)
    }

    private func install(_ attachment: FlowchartAttachment, at index: Int) {
        attachment.updateViewportImage()
        let range = NSRange(location: index, length: 1)
        textStorage?.addAttribute(.attachment, value: attachment, range: range)
        layoutManager?.invalidateDisplay(forCharacterRange: range)
        needsDisplay = true
    }
}

extension FlowchartAttachment {
    func interactiveCopy() -> FlowchartAttachment {
        let copy = FlowchartAttachment()
        copy.fileWrapper = fileWrapper
        copy.originalImage = originalImage ?? image
        copy.image = copy.originalImage
        copy.viewport = viewport
        return copy
    }

    func updateViewportImage() {
        guard let originalImage else { return }
        guard viewport.scale > 1 else { image = originalImage; return }
        let size = originalImage.size
        let viewport = viewport
        image = NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).addClip()
            originalImage.draw(in: NSRect(x: -viewport.origin.x * size.width * viewport.scale,
                                         y: -viewport.origin.y * size.height * viewport.scale,
                                         width: size.width * viewport.scale, height: size.height * viewport.scale),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}
