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
                onCopy: { },
                onSave: { }
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
            minimumSize: minimumContentSize,
            onCopy: { [weak self] in
                self?.copyAndClose()
            },
            onSave: { [weak self] in
                self?.saveToFile()
            }
        )

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

    private func saveToFile() {
        guard let window, window.attachedSheet == nil else { return }
        editorDocument.commitPendingTextInsertion()

        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [ScreenshotExportFormat.png.contentType]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Screenshot \(dateFormatter.string(from: Date()))"
        let options = ScreenshotSaveOptionsView(panel: panel)
        panel.accessoryView = options

        panel.beginSheetModal(for: window) { [weak self] response in
            panel.orderOut(nil)
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                guard let image = self.editorDocument.renderCompositeImage() else {
                    throw ScreenshotExportError.renderingFailed
                }
                try options.format.write(image, to: url, jpegQuality: options.jpegQuality)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The screenshot could not be saved."
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
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
            width: max(maximumContentSize.width - ScreenshotEditorView.sidebarWidth, 0),
            height: maximumContentSize.height
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
            width: min(
                max(fittedCanvasSize.width + ScreenshotEditorView.sidebarWidth, minimumContentSize.width),
                maximumContentSize.width
            ),
            height: min(max(fittedCanvasSize.height, minimumContentSize.height), maximumContentSize.height)
        )
        let canvasWidth = max(contentSize.width - ScreenshotEditorView.sidebarWidth, 0)

        // Center the image over its captured location, including minimum-size letterboxing.
        return CGRect(
            x: capture.selectionRect.midX - canvasWidth * 0.5 - ScreenshotEditorView.sidebarWidth,
            y: capture.selectionRect.midY - contentSize.height * 0.5,
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

@MainActor
private final class ScreenshotSaveOptionsView: NSStackView {
    private weak var panel: NSSavePanel?
    private let formatPicker = NSPopUpButton()
    private let qualitySlider = NSSlider(value: 0.9, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let qualityValue = NSTextField(labelWithString: "90%")
    private let qualityLabel = NSTextField(labelWithString: "JPEG quality:")

    var format: ScreenshotExportFormat {
        ScreenshotExportFormat.allCases[formatPicker.indexOfSelectedItem]
    }

    var jpegQuality: Double { qualitySlider.doubleValue }

    init(panel: NSSavePanel) {
        self.panel = panel
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatPicker.addItems(withTitles: ScreenshotExportFormat.allCases.map(\.rawValue))
        formatPicker.target = self
        formatPicker.action = #selector(formatChanged)
        formatPicker.setAccessibilityLabel("Image format")
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.setAccessibilityLabel("JPEG quality")
        qualityValue.alignment = .right
        qualityValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        qualityValue.setAccessibilityLabel("JPEG quality percentage")

        addArrangedSubview(NSStackView(views: [formatLabel, formatPicker]))
        addArrangedSubview(NSStackView(views: [qualityLabel, qualitySlider, qualityValue]))
        NSLayoutConstraint.activate([
            formatLabel.widthAnchor.constraint(equalToConstant: 95),
            qualityLabel.widthAnchor.constraint(equalTo: formatLabel.widthAnchor),
            formatPicker.widthAnchor.constraint(equalToConstant: 210),
            qualitySlider.widthAnchor.constraint(equalToConstant: 160),
            qualityValue.widthAnchor.constraint(equalToConstant: 42)
        ])
        updateQualityControls()
        setFrameSize(fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func formatChanged() {
        guard let panel else { return }
        panel.allowedContentTypes = [format.contentType]
        updateQualityControls()
    }

    @objc private func qualityChanged() {
        qualityValue.stringValue = "\(Int((jpegQuality * 100).rounded()))%"
    }

    private func updateQualityControls() {
        let isJPEG = format == .jpeg
        qualitySlider.isEnabled = isJPEG
        qualityLabel.textColor = isJPEG ? .labelColor : .disabledControlTextColor
        qualityValue.textColor = qualityLabel.textColor
    }
}
