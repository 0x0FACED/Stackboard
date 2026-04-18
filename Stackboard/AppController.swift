import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let historyStore = ClipboardHistoryStore()
    let hotkeySettingsStore = HotkeySettingsStore()

    private let clipboardMonitor: ClipboardMonitor
    private let hotKeys: GlobalHotKeyCenter
    private var screenshotCoordinator: ScreenshotCoordinator?
    private var historyWindowController: HistoryWindowController?
    private var historyImagePreviewWindowController: HistoryImagePreviewWindowController?
    private var editorWindowController: ScreenshotEditorWindowController?
    private var hotkeySettingsWindowController: HotkeySettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        clipboardMonitor = ClipboardMonitor(historyStore: historyStore)
        hotKeys = GlobalHotKeyCenter()
        screenshotCoordinator = ScreenshotCoordinator()

        configureHotKeys()
        clipboardMonitor.start()
    }

    func startScreenshot() {
        NSApp.activate(ignoringOtherApps: true)
        screenshotCoordinator?.beginSelection { [weak self] image in
            self?.presentEditor(for: image)
        }
    }

    func openHistoryWindow() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController(appController: self)
        }

        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openHotkeySettingsWindow() {
        if hotkeySettingsWindowController == nil {
            hotkeySettingsWindowController = HotkeySettingsWindowController(appController: self, store: hotkeySettingsStore)
        }

        hotkeySettingsWindowController?.showWindow(nil)
        hotkeySettingsWindowController?.window?.makeKeyAndOrderFront(nil)
        refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentEditor(for image: NSImage) {
        editorWindowController?.close()
        editorWindowController = ScreenshotEditorWindowController(appController: self, image: image)
        editorWindowController?.showWindow(nil)
        editorWindowController?.window?.makeKeyAndOrderFront(nil)
        refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func copyToClipboard(_ item: ClipboardHistoryItem) {
        switch item.kind {
        case .text:
            guard let text = item.textValue else {
                return
            }
            ClipboardService.copy(text)
            historyStore.ingest(.text(text))
        case .image:
            guard let image = historyStore.image(for: item) else {
                return
            }
            ClipboardService.copy(image)
            historyStore.ingest(.image(image))
        case .file:
            guard let fileURL = historyStore.fileURL(for: item) else {
                presentMissingFileAlert(for: item)
                return
            }

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                presentMissingFileAlert(for: item)
                return
            }

            ClipboardService.copy(fileURL)
            historyStore.ingest(.file(fileURL))
        }
    }

    func copyImageToClipboard(_ image: NSImage) {
        ClipboardService.copy(image)
        historyStore.ingest(.image(image))
    }

    func clearHistory() {
        closeHistoryPreview()
        historyStore.clear()
    }

    func togglePinnedHistoryItem(_ item: ClipboardHistoryItem) {
        historyStore.togglePin(item)
    }

    func deleteHistoryItem(_ item: ClipboardHistoryItem) {
        if historyImagePreviewWindowController?.itemID == item.id {
            closeHistoryPreview()
        }
        historyStore.delete(item)
    }

    func toggleHistoryPreview(for item: ClipboardHistoryItem) {
        guard let image = historyStore.image(for: item) else {
            return
        }

        if historyImagePreviewWindowController?.itemID == item.id,
           historyImagePreviewWindowController?.window?.isVisible == true {
            closeHistoryPreview()
            return
        }

        historyImagePreviewWindowController?.close()
        historyImagePreviewWindowController = HistoryImagePreviewWindowController(appController: self, item: item, image: image)
        historyImagePreviewWindowController?.showWindow(nil)
        historyImagePreviewWindowController?.window?.makeKeyAndOrderFront(nil)
        refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeHistoryPreview() {
        historyImagePreviewWindowController?.close()
        historyImagePreviewWindowController = nil
        refreshActivationPolicy()
    }

    func foregroundWindowDidBecomeKey() {
        refreshActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func historyWindowDidClose() {
        refreshActivationPolicy()
    }

    func editorWindowDidClose(_ controller: ScreenshotEditorWindowController) {
        if editorWindowController === controller {
            editorWindowController = nil
        }
        refreshActivationPolicy()
    }

    func hotkeySettingsWindowDidClose() {
        refreshActivationPolicy()
    }

    func historyPreviewWindowDidClose(_ controller: HistoryImagePreviewWindowController) {
        if historyImagePreviewWindowController === controller {
            historyImagePreviewWindowController = nil
        }
        refreshActivationPolicy()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func configureHotKeys() {
        hotkeySettingsStore.$screenshotShortcut
            .combineLatest(hotkeySettingsStore.$historyShortcut, hotkeySettingsStore.$isRecordingShortcut)
            .sink { [weak self] screenshotShortcut, historyShortcut, isRecordingShortcut in
                guard let self else {
                    return
                }

                if isRecordingShortcut {
                    self.hotKeys.unregister(id: 1)
                    self.hotKeys.unregister(id: 2)
                    self.hotkeySettingsStore.setRegistrationMessage(nil)
                    return
                }

                self.registerHotkeys(
                    screenshotShortcut: screenshotShortcut,
                    historyShortcut: historyShortcut
                )
            }
            .store(in: &cancellables)
    }

    private func registerHotkeys(
        screenshotShortcut: HotkeyShortcut,
        historyShortcut: HotkeyShortcut
    ) {
        let screenshotStatus = hotKeys.register(
            id: 1,
            keyCode: screenshotShortcut.keyCode,
            modifiers: screenshotShortcut.modifiers
        ) { [weak self] in
            self?.startScreenshot()
        }

        let historyStatus = hotKeys.register(
            id: 2,
            keyCode: historyShortcut.keyCode,
            modifiers: historyShortcut.modifiers
        ) { [weak self] in
            self?.openHistoryWindow()
        }

        var messages: [String] = []

        if screenshotStatus != noErr {
            messages.append(conflictMessage(for: .screenshot, shortcut: screenshotShortcut, status: screenshotStatus))
        }

        if historyStatus != noErr {
            messages.append(conflictMessage(for: .history, shortcut: historyShortcut, status: historyStatus))
        }

        hotkeySettingsStore.setRegistrationMessage(messages.isEmpty ? nil : messages.joined(separator: " "))
    }

    private func conflictMessage(for action: HotkeyAction, shortcut: HotkeyShortcut, status: OSStatus) -> String {
        if status == eventHotKeyExistsErr {
            return "\(action.title) uses \(shortcut.displayString), but macOS or another app already owns that shortcut."
        }

        return "\(action.title) could not register \(shortcut.displayString) (error \(status))."
    }

    private func presentMissingFileAlert(for item: ClipboardHistoryItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The original file is no longer available."
        alert.informativeText = item.filePath ?? "Stackboard only stores the file path, and that path no longer exists."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func refreshActivationPolicy() {
        let targetPolicy: NSApplication.ActivationPolicy = hasVisibleForegroundWindows ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }
    }

    private var hasVisibleForegroundWindows: Bool {
        [
            historyWindowController?.window?.isVisible,
            historyImagePreviewWindowController?.window?.isVisible,
            editorWindowController?.window?.isVisible,
            hotkeySettingsWindowController?.window?.isVisible
        ].contains(true)
    }
}
