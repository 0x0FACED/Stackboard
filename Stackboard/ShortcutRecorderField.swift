import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderField: NSViewRepresentable {
    let shortcut: HotkeyShortcut
    let onUpdate: (HotkeyShortcut) -> Bool
    let onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.shortcut = shortcut
        button.onShortcutChange = onUpdate
        button.onRecordingChange = onRecordingChange
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.onShortcutChange = onUpdate
        nsView.onRecordingChange = onRecordingChange
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut = HotkeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey)) {
        didSet { updateTitle() }
    }

    var onShortcutChange: ((HotkeyShortcut) -> Bool)?
    var onRecordingChange: ((Bool) -> Void)?

    private var isRecording = false {
        didSet {
            updateTitle()
            onRecordingChange?(isRecording)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        isBordered = true
        focusRingType = .default
        font = .systemFont(ofSize: 13, weight: .medium)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }

        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        guard isRecording else {
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        guard let shortcut = HotkeyShortcut(event: event) else {
            NSSound.beep()
            return
        }

        let accepted = onShortcutChange?(shortcut) ?? false
        if accepted {
            self.shortcut = shortcut
            window?.makeFirstResponder(nil)
        } else {
            NSSound.beep()
        }
    }

    private func updateTitle() {
        title = isRecording ? "Press new shortcut" : shortcut.displayString
    }
}
