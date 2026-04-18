import AppKit
import SwiftUI

@MainActor
final class HotkeySettingsWindowController: NSWindowController, NSWindowDelegate {
    private let appController: AppController

    init(appController: AppController, store: HotkeySettingsStore) {
        self.appController = appController

        let hostingController = NSHostingController(
            rootView: HotkeySettingsView(store: store)
        )

        let window = EscapeAwareWindow(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.center()
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
        appController.hotkeySettingsWindowDidClose()
    }
}

private struct HotkeySettingsView: View {
    @ObservedObject var store: HotkeySettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))
                Text("Click a field, then press a new shortcut. At least one modifier key is required.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                hotkeyRow(for: .screenshot)
                hotkeyRow(for: .history)
            }

            if let validationMessage = store.validationMessage {
                Text(validationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            if let registrationMessage = store.registrationMessage {
                Text(registrationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Reset Defaults") {
                    store.resetToDefaults()
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 460, height: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func hotkeyRow(for action: HotkeyAction) -> some View {
        HStack {
            Text(action.title)
                .frame(width: 150, alignment: .leading)

            ShortcutRecorderField(
                shortcut: store.shortcut(for: action),
                onUpdate: { shortcut in
                    store.update(action: action, to: shortcut)
                },
                onRecordingChange: { isRecording in
                    store.setRecordingShortcut(isRecording)
                }
            )
            .frame(width: 220, height: 30)
        }
    }
}
