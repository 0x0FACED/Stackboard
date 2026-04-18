import AppKit
import CoreGraphics

struct DesktopCapture {
    let image: NSImage
    let desktopFrame: CGRect
    let pixelSize: CGSize
}

@MainActor
enum DesktopCaptureFactory {
    static func captureDesktop() -> DesktopCapture? {
        let screens = NSScreen.screens
        guard screens.isEmpty == false else {
            return nil
        }

        let desktopFrame = screens
            .map(\.frame)
            .reduce(CGRect.null) { $0.union($1) }

        guard let cgImage = CGWindowListCreateImage(
            .infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }

        return DesktopCapture(
            image: NSImage(cgImage: cgImage, size: desktopFrame.size),
            desktopFrame: desktopFrame,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
