import AppKit

enum StatusBarIcon {
    static let menuBarImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let backRect = NSRect(x: 3.5, y: 3.0, width: 8.8, height: 8.8)
        let frontRect = NSRect(x: 6.7, y: 6.2, width: 8.8, height: 8.8)

        let backPath = NSBezierPath(roundedRect: backRect, xRadius: 2.3, yRadius: 2.3)
        backPath.lineWidth = 1.4
        NSColor.black.withAlphaComponent(0.78).setStroke()
        backPath.stroke()

        let frontPath = NSBezierPath(roundedRect: frontRect, xRadius: 2.3, yRadius: 2.3)
        frontPath.lineWidth = 1.6
        NSColor.black.setStroke()
        frontPath.stroke()

        let accentPath = NSBezierPath()
        accentPath.lineWidth = 1.8
        accentPath.lineCapStyle = .round
        accentPath.move(to: NSPoint(x: 8.9, y: 13.2))
        accentPath.line(to: NSPoint(x: 13.3, y: 8.8))
        NSColor.black.setStroke()
        accentPath.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}
