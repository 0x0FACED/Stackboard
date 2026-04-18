import AppKit
import SwiftUI

@MainActor
final class HistoryImagePreviewWindowController: NSWindowController, NSWindowDelegate {
    let itemID: UUID
    private let appController: AppController

    init(appController: AppController, item: ClipboardHistoryItem, image: NSImage) {
        self.appController = appController
        itemID = item.id

        let hostingController = NSHostingController(
            rootView: HistoryImagePreviewView(item: item, image: image)
        )

        let imageSize = image.size
        let maxWidth: CGFloat = 1100
        let maxHeight: CGFloat = 900
        let width = min(max(imageSize.width + 80, 520), maxWidth)
        let height = min(max(imageSize.height + 120, 420), maxHeight)

        let window = EscapeAwareWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Preview"
        window.center()
        window.toolbarStyle = .unified
        window.collectionBehavior = [.managed, .moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        window.onEscape = { [weak window] in
            window?.close()
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
        appController.historyPreviewWindowDidClose(self)
    }
}

private struct HistoryImagePreviewView: View {
    let item: ClipboardHistoryItem
    let image: NSImage

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.menuTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(item.detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)

            GeometryReader { proxy in
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.96),
                            Color.black.opacity(0.88)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: max(proxy.size.width - 48, 100),
                            height: max(proxy.size.height - 48, 100)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                }
            }
        }
        .background(Color.black)
    }
}
