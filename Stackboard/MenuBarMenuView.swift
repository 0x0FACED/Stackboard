import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var appController: AppController
    @ObservedObject private var historyStore: ClipboardHistoryStore
    @ObservedObject private var hotkeySettingsStore: HotkeySettingsStore

    init(appController: AppController) {
        _appController = ObservedObject(wrappedValue: appController)
        _historyStore = ObservedObject(wrappedValue: appController.historyStore)
        _hotkeySettingsStore = ObservedObject(wrappedValue: appController.hotkeySettingsStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            commands

            Divider()
                .padding(.vertical, 2)

            recentSection

            Divider()
                .padding(.vertical, 2)

            Button {
                appController.openHistoryWindow()
            } label: {
                MenuBarCommandLabel(
                    title: "Open Clipboard History",
                    systemImage: "clock.arrow.circlepath",
                    shortcut: hotkeySettingsStore.historyShortcut.displayString
                )
            }
            .buttonStyle(MenuBarRowButtonStyle())
            .accessibilityLabel("Open Clipboard History")
            .accessibilityHint("Shortcut: \(hotkeySettingsStore.historyShortcut.displayString)")
        }
        .padding(12)
        .frame(width: 360)
        .background(ClipboardUIStyle.contentBackground)
    }

    private var header: some View {
        HStack {
            Text("Stackboard")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Menu {
                Button("Keyboard Shortcuts…") {
                    appController.openHotkeySettingsWindow()
                }

                Button("Clear History", role: .destructive) {
                    appController.clearHistory()
                }
                .disabled(historyStore.items.isEmpty)

                Divider()

                Button("Quit Stackboard") {
                    appController.quit()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
            .help("More actions")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private var commands: some View {
        VStack(spacing: 2) {
            Button {
                appController.startScreenshot()
            } label: {
                MenuBarCommandLabel(
                    title: "New Screenshot",
                    systemImage: "viewfinder",
                    shortcut: hotkeySettingsStore.screenshotShortcut.displayString
                )
            }
            .buttonStyle(MenuBarRowButtonStyle())
            .accessibilityLabel("New Screenshot")
            .accessibilityHint("Shortcut: \(hotkeySettingsStore.screenshotShortcut.displayString)")

            Menu {
                Button("From File…") {
                    appController.openImageFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("From Clipboard") {
                    appController.openImageFromClipboard()
                }
            } label: {
                MenuBarCommandLabel(
                    title: "Open Image",
                    systemImage: "photo",
                    showsDisclosure: true
                )
            }
            .menuStyle(.button)
            .buttonStyle(MenuBarRowButtonStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel("Open Image")
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            if historyStore.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No clips yet")
                        .font(.system(size: 13, weight: .medium))
                    Text("Copy text, images, or files to see them here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(historyStore.items.prefix(8)) { item in
                            MenuBarRecentRow(
                                item: item,
                                image: historyStore.thumbnail(for: item, maxDimension: 72)
                            ) {
                                appController.copyToClipboard(item)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(min(historyStore.items.count, 8)) * 52, 312))
            }
        }
    }
}

private struct MenuBarCommandLabel: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(ClipboardUIStyle.accent)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }

            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 34)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MenuBarRecentRow: View {
    let item: ClipboardHistoryItem
    let image: NSImage?
    let onCopy: () -> Void

    var body: some View {
        let isMissingFile = item.kind == .file && !item.fileExists
        let detail = item.kind == .text ? "Text • \(item.detailText)" : item.detailText

        Button(action: onCopy) {
            HStack(spacing: 10) {
                ClipboardItemThumbnail(item: item, image: image, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.menuTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .disabled(isMissingFile)
        .accessibilityLabel(item.menuTitle)
        .accessibilityValue(detail)
        .accessibilityHint(isMissingFile ? "The original file is no longer available." : "Copy to the clipboard.")
        .help(isMissingFile ? "The original file is no longer available." : "Copy to Clipboard")
    }
}

private struct MenuBarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused && isEnabled ? ClipboardUIStyle.accent : .clear, lineWidth: 2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { isHovering = $0 }
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed {
                return ClipboardUIStyle.accent.opacity(0.2)
            }
            return isHovering ? ClipboardUIStyle.selectionFill : .clear
        }
    }
}
