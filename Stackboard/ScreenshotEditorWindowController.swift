import AppKit
import SwiftUI

@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    private let appController: AppController
    private let editorDocument: EditorDocument

    init(appController: AppController, image: NSImage) {
        self.appController = appController
        editorDocument = EditorDocument(baseImage: image)

        let hostingController = NSHostingController(
            rootView: ScreenshotEditorView(document: editorDocument) { }
        )

        let frame = Self.initialFrame(for: image)
        let window = EscapeAwareWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stackboard Editor"
        window.center()
        window.collectionBehavior = [.managed, .moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        hostingController.rootView = ScreenshotEditorView(document: editorDocument) { [weak self] in
            self?.copyAndClose()
        }
        window.onEscape = { [weak self] in
            guard let self else {
                return
            }

            if self.editorDocument.handleEscape() {
                return
            }

            self.copyAndClose()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        appController.foregroundWindowDidBecomeKey()
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        appController.editorWindowDidClose(self)
    }

    private func copyAndClose() {
        editorDocument.commitPendingTextInsertion()
        if let image = editorDocument.renderCompositeImage() {
            appController.copyImageToClipboard(image)
        }
        close()
    }

    private static func initialFrame(for image: NSImage) -> CGRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let chromePadding = CGSize(width: 56, height: 126)
        let maxCanvasSize = CGSize(
            width: visibleFrame.width * 0.9 - chromePadding.width,
            height: visibleFrame.height * 0.82 - chromePadding.height
        )
        let naturalCanvasSize = image.size

        let scale = min(
            1,
            min(
                maxCanvasSize.width / max(naturalCanvasSize.width, 1),
                maxCanvasSize.height / max(naturalCanvasSize.height, 1)
            )
        )

        let fittedCanvasSize = CGSize(
            width: naturalCanvasSize.width * scale,
            height: naturalCanvasSize.height * scale
        )

        let width = min(
            max(fittedCanvasSize.width + chromePadding.width, 900),
            visibleFrame.width * 0.96
        )
        let height = min(
            max(fittedCanvasSize.height + chromePadding.height, 620),
            visibleFrame.height * 0.92
        )

        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}
