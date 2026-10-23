import AppKit
import SwiftUI

@MainActor
final class ImageOpenCoordinator {
    private var openPanel: NSOpenPanel?

    func openFile(onOpen: @escaping (NSImage, String) -> Void) {
        if let openPanel {
            NSApp.activate(ignoringOtherApps: true)
            openPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Open Image"
        panel.prompt = "Open"
        panel.allowedContentTypes = EditorImageImport.supportedContentTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        openPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            panel.orderOut(nil)
            self?.openPanel = nil
            guard response == .OK, let url = panel.url else { return }
            do {
                let image = try EditorImageImport.fromFile(url)
                onOpen(image, url.lastPathComponent)
            } catch {
                self?.showError(error, sourceName: url.lastPathComponent)
            }
        }
    }

    func openClipboard(
        from pasteboard: NSPasteboard = .general,
        onOpen: (NSImage, String) -> Void
    ) {
        do {
            let image = try EditorImageImport.fromPasteboard(pasteboard)
            onOpen(image, "Clipboard Image")
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error, sourceName: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The image could not be opened."
        alert.informativeText = sourceName.map { "\($0)\n\(error.localizedDescription)" } ?? error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

struct ImageOpenCommands: Commands {
    let openFile: () -> Void
    let openClipboard: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Image…", action: openFile)
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Image from Clipboard", action: openClipboard)
        }
    }
}
