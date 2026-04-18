import AppKit

@MainActor
final class ScreenshotSelectionWindowController: NSWindowController {
    private let completion: (CGRect?) -> Void
    private let desktopFrame: CGRect

    init(capture: DesktopCapture, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        desktopFrame = capture.desktopFrame

        let window = EscapeAwareWindow(
            contentRect: desktopFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.hasShadow = false

        let selectionView = ScreenshotSelectionView(
            frame: CGRect(origin: .zero, size: desktopFrame.size),
            screenshot: capture.image
        )
        selectionView.frame = CGRect(origin: .zero, size: desktopFrame.size)
        selectionView.autoresizingMask = [.width, .height]
        window.contentView = selectionView
        super.init(window: window)

        selectionView.onSelection = { [weak self] localRect in
            guard let self else {
                return
            }

            let desktopRect = CGRect(
                x: localRect.minX + self.desktopFrame.minX,
                y: localRect.minY + self.desktopFrame.minY,
                width: localRect.width,
                height: localRect.height
            )
            self.finish(with: desktopRect)
        }
        window.onEscape = { [weak self] in
            self?.finish(with: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(with rect: CGRect?) {
        close()
        completion(rect)
    }
}
