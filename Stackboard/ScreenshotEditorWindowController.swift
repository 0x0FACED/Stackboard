import AppKit
import SwiftUI

@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    private let appController: AppController
    private let editorDocument: EditorDocument

    /// Fits the native-point-size canvas to its captured screen, retaining an attainable fixed minimum.
    init(appController: AppController, capture: ScreenshotCapture) {
        self.appController = appController
        let image = capture.image
        editorDocument = EditorDocument(baseImage: image)

        let visibleFrame = Self.visibleFrame(for: capture.selectionRect)
        let window = EscapeAwareWindow(
            contentRect: CGRect(
                origin: capture.selectionRect.origin,
                size: ScreenshotEditorView.minimumContentSize
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stackboard Editor"
        window.collectionBehavior = [.managed, .moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        let maximumContentSize = window.contentRect(forFrameRect: visibleFrame).size
        let minimumContentSize = CGSize(
            width: min(ScreenshotEditorView.minimumContentSize.width, maximumContentSize.width),
            height: min(ScreenshotEditorView.minimumContentSize.height, maximumContentSize.height)
        )
        let hostingController = NSHostingController(
            rootView: ScreenshotEditorView(
                document: editorDocument,
                minimumSize: minimumContentSize,
                onCopy: { }
            )
        )
        hostingController.sizingOptions = [.minSize]
        hostingController.view.autoresizingMask = [.width, .height]
        window.contentViewController = hostingController
        window.contentMinSize = minimumContentSize

        super.init(window: window)

        window.delegate = self
        hostingController.rootView = ScreenshotEditorView(
            document: editorDocument,
            minimumSize: minimumContentSize
        ) { [weak self] in
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

        // Hosting attachment and initial layout can replace the window's requested size.
        hostingController.view.layoutSubtreeIfNeeded()
        let contentRect = Self.initialContentRect(
            for: capture,
            maximumContentSize: maximumContentSize,
            minimumContentSize: minimumContentSize
        )
        let frame = window.frameRect(forContentRect: contentRect)
        window.setFrame(Self.clampedFrame(frame, to: visibleFrame), display: false)
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

    private static func visibleFrame(for selectionRect: CGRect) -> CGRect {
        let screen = NSScreen.screens.max { first, second in
            let firstOverlap = first.frame.intersection(selectionRect)
            let secondOverlap = second.frame.intersection(selectionRect)
            let firstArea = firstOverlap.isNull ? 0 : firstOverlap.width * firstOverlap.height
            let secondArea = secondOverlap.isNull ? 0 : secondOverlap.width * secondOverlap.height
            return firstArea < secondArea
        }
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func initialContentRect(
        for capture: ScreenshotCapture,
        maximumContentSize: CGSize,
        minimumContentSize: CGSize
    ) -> CGRect {
        let naturalCanvasSize = capture.image.size
        let maximumCanvasSize = CGSize(
            width: maximumContentSize.width,
            height: max(maximumContentSize.height - ScreenshotEditorView.chromeHeight, 0)
        )
        let scale = min(
            1,
            min(
                maximumCanvasSize.width / max(naturalCanvasSize.width, 1),
                maximumCanvasSize.height / max(naturalCanvasSize.height, 1)
            )
        )
        let fittedCanvasSize = CGSize(
            width: naturalCanvasSize.width * scale,
            height: naturalCanvasSize.height * scale
        )
        let contentSize = CGSize(
            width: min(max(fittedCanvasSize.width, minimumContentSize.width), maximumContentSize.width),
            height: min(
                max(fittedCanvasSize.height + ScreenshotEditorView.chromeHeight, minimumContentSize.height),
                maximumContentSize.height
            )
        )
        let canvasHeight = max(contentSize.height - ScreenshotEditorView.chromeHeight, 0)

        // Center the image over its captured location, including minimum-size letterboxing.
        return CGRect(
            x: capture.selectionRect.midX - contentSize.width * 0.5,
            y: capture.selectionRect.midY - canvasHeight * 0.5,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private static func clampedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }
}
