import AppKit
import Carbon
import Foundation

enum HotkeyAction: String, CaseIterable, Identifiable {
    case screenshot
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot:
            return "New Screenshot"
        case .history:
            return "Open History"
        }
    }

    var storageKey: String {
        "hotkey.\(rawValue)"
    }

    var defaultShortcut: HotkeyShortcut {
        switch self {
        case .screenshot:
            return HotkeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        case .history:
            return HotkeyShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        }
    }
}

struct HotkeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            return nil
        }

        let keyCode = UInt32(event.keyCode)
        guard Self.disallowedKeyCodes.contains(keyCode) == false else {
            return nil
        }

        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    var displayString: String {
        var symbols = ""

        if modifiers & UInt32(controlKey) != 0 {
            symbols += "⌃"
        }
        if modifiers & UInt32(optionKey) != 0 {
            symbols += "⌥"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            symbols += "⇧"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            symbols += "⌘"
        }

        return symbols + Self.keyTitle(for: keyCode)
    }

    private static let disallowedKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command),
        UInt32(kVK_RightCommand),
        UInt32(kVK_Shift),
        UInt32(kVK_RightShift),
        UInt32(kVK_Option),
        UInt32(kVK_RightOption),
        UInt32(kVK_Control),
        UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock),
        UInt32(kVK_Function)
    ]

    private static let keyTitles: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A",
        UInt32(kVK_ANSI_B): "B",
        UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E",
        UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J",
        UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_N): "N",
        UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S",
        UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V",
        UInt32(kVK_ANSI_W): "W",
        UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y",
        UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_1): "1",
        UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4",
        UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_ForwardDelete): "FnDelete",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12"
    ]

    private static func keyTitle(for keyCode: UInt32) -> String {
        keyTitles[keyCode] ?? "Key \(keyCode)"
    }
}

func carbonModifiers(from modifierFlags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0

    if modifierFlags.contains(.command) {
        modifiers |= UInt32(cmdKey)
    }
    if modifierFlags.contains(.option) {
        modifiers |= UInt32(optionKey)
    }
    if modifierFlags.contains(.control) {
        modifiers |= UInt32(controlKey)
    }
    if modifierFlags.contains(.shift) {
        modifiers |= UInt32(shiftKey)
    }

    return modifiers
}
