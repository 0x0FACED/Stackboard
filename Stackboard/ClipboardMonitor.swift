import AppKit

@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private let historyStore: ClipboardHistoryStore
    private var lastChangeCount: Int
    private var timer: Timer?

    init(historyStore: ClipboardHistoryStore) {
        self.historyStore = historyStore
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        timer?.tolerance = 0.1
        captureCurrentClipboard()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func captureCurrentClipboard() {
        if let snapshot = ClipboardService.currentSnapshot(from: pasteboard) {
            historyStore.ingest(snapshot)
        }
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount
        captureCurrentClipboard()
    }
}
