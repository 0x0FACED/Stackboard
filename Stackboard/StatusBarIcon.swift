import AppKit

enum StatusBarIcon {
    static let menuBarImage: NSImage = {
        guard let image = NSImage(named: NSImage.Name("MenuBarIcon")) else {
            preconditionFailure("Missing MenuBarIcon asset")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
