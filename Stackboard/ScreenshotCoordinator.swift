import AppKit
import CoreGraphics

@MainActor
final class ScreenshotCoordinator {
    private var selectionWindowController: ScreenshotSelectionWindowController?
    private(set) var isSelecting = false

    /// Ignores requests during capture/selection; an open editor does not block a new capture.
    func beginSelection(onCapture: @escaping (ScreenshotCapture) -> Void) {
        guard isSelecting == false else {
            return
        }
        isSelecting = true
        NSApp.activate(ignoringOtherApps: true)

        guard ensureScreenCapturePermission() else {
            isSelecting = false
            return
        }

        guard let capture = DesktopCaptureFactory.captureDesktop() else {
            showAlert(
                title: "Screenshot capture failed",
                message: "Stackboard could not capture the screen."
            )
            isSelecting = false
            return
        }

        selectionWindowController = ScreenshotSelectionWindowController(capture: capture) { [weak self] selectedRect in
            guard let self else {
                return
            }
            self.selectionWindowController = nil
            self.isSelecting = false

            guard
                let selectedRect,
                let image = self.crop(capture: capture, selectedRect: selectedRect)
            else {
                return
            }

            onCapture(ScreenshotCapture(image: image, selectionRect: selectedRect))
        }
        selectionWindowController?.present()
    }

    private func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        guard CGRequestScreenCaptureAccess() else {
            showAlert(
                title: "Screen Recording permission is required",
                message: "Enable Stackboard in System Settings → Privacy & Security → Screen Recording, then try again."
            )
            return false
        }

        return true
    }

    private func crop(capture: DesktopCapture, selectedRect: CGRect) -> NSImage? {
        let localRect = CGRect(
            x: selectedRect.minX - capture.desktopFrame.minX,
            y: selectedRect.minY - capture.desktopFrame.minY,
            width: selectedRect.width,
            height: selectedRect.height
        )

        let scaleX = capture.pixelSize.width / capture.desktopFrame.width
        let scaleY = capture.pixelSize.height / capture.desktopFrame.height

        let pixelWidth = max(Int(round(localRect.width * scaleX)), 1)
        let pixelHeight = max(Int(round(localRect.height * scaleY)), 1)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = localRect.size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        capture.image.draw(
            in: CGRect(origin: .zero, size: localRect.size),
            from: localRect,
            operation: .copy,
            fraction: 1
        )

        let image = NSImage(size: localRect.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
