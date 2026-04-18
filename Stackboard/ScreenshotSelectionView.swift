import AppKit

final class ScreenshotSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?

    private let screenshot: NSImage
    private var dragStartPoint: CGPoint?
    private var currentSelection: CGRect = .zero
    private var selectionTrackingArea: NSTrackingArea?

    init(frame frameRect: NSRect, screenshot: NSImage) {
        self.screenshot = screenshot
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        screenshot.draw(in: bounds)

        let overlayPath = NSBezierPath(rect: bounds)
        if currentSelection.isEmpty == false {
            overlayPath.appendRect(currentSelection)
        }

        NSColor.black.withAlphaComponent(0.46).setFill()
        overlayPath.windingRule = .evenOdd
        overlayPath.fill()

        if currentSelection.isEmpty == false {
            NSColor.white.setStroke()
            let selectionPath = NSBezierPath(rect: currentSelection)
            selectionPath.lineWidth = 2
            selectionPath.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]

        NSString(string: "Select an area").draw(at: CGPoint(x: 24, y: bounds.height - 48), withAttributes: attributes)
        NSString(string: "Drag to capture • Esc to cancel").draw(at: CGPoint(x: 24, y: bounds.height - 70), withAttributes: subtitleAttributes)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        if let selectionTrackingArea {
            removeTrackingArea(selectionTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        selectionTrackingArea = trackingArea

        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        currentSelection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        currentSelection = CGRect(
            x: min(dragStartPoint.x, point.x),
            y: min(dragStartPoint.y, point.y),
            width: abs(point.x - dragStartPoint.x),
            height: abs(point.y - dragStartPoint.y)
        ).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartPoint = nil
        }

        guard currentSelection.width >= 8, currentSelection.height >= 8 else {
            currentSelection = .zero
            needsDisplay = true
            return
        }

        onSelection?(currentSelection)
    }
}
