import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var appController: AppController
    @ObservedObject private var historyStore = AppController.shared.historyStore
    @ObservedObject private var hotkeySettingsStore = AppController.shared.hotkeySettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("New Screenshot    \(hotkeySettingsStore.screenshotShortcut.displayString)") {
                appController.startScreenshot()
            }

            Button("Open Clipboard History    \(hotkeySettingsStore.historyShortcut.displayString)") {
                appController.openHistoryWindow()
            }

            Button("Keyboard Shortcuts…") {
                appController.openHotkeySettingsWindow()
            }

            Divider()

            if historyStore.items.isEmpty {
                Text("Clipboard history is empty.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("Recent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(historyStore.items.prefix(8))) { item in
                    Button {
                        appController.copyToClipboard(item)
                    } label: {
                        HStack(spacing: 8) {
                            MenuBarPreview(item: item, store: historyStore)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.menuTitle)
                                    .lineLimit(1)
                                Text(item.detailText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(item.kind == .file && item.fileExists == false)
                    .opacity(item.kind == .file && item.fileExists == false ? 0.6 : 1)
                }
            }

            Divider()

            Button("Clear History") {
                appController.clearHistory()
            }

            Button("Quit Stackboard") {
                appController.quit()
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

private struct MenuBarPreview: View {
    let item: ClipboardHistoryItem
    @ObservedObject var store: ClipboardHistoryStore

    var body: some View {
        ZStack {
            if item.kind == .image, let image = store.thumbnail(for: item, maxDimension: 34) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if item.kind == .file {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.14))
                Image(systemName: item.fileExists ? "doc" : "exclamationmark.triangle")
                    .foregroundStyle(item.fileExists ? Color.secondary : Color.orange)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.14))
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
