import Combine
import Foundation

@MainActor
final class HotkeySettingsStore: ObservableObject {
    @Published private(set) var screenshotShortcut: HotkeyShortcut
    @Published private(set) var historyShortcut: HotkeyShortcut
    @Published private(set) var isRecordingShortcut = false
    @Published var validationMessage: String?
    @Published var registrationMessage: String?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        screenshotShortcut = Self.loadShortcut(for: .screenshot, defaults: defaults)
        historyShortcut = Self.loadShortcut(for: .history, defaults: defaults)
    }

    func shortcut(for action: HotkeyAction) -> HotkeyShortcut {
        switch action {
        case .screenshot:
            return screenshotShortcut
        case .history:
            return historyShortcut
        }
    }

    @discardableResult
    func update(action: HotkeyAction, to shortcut: HotkeyShortcut) -> Bool {
        let otherAction: HotkeyAction = action == .screenshot ? .history : .screenshot
        if shortcut == self.shortcut(for: otherAction) {
            validationMessage = "This shortcut is already assigned to \(otherAction.title.lowercased())."
            return false
        }

        validationMessage = nil
        persist(shortcut, for: action)

        switch action {
        case .screenshot:
            screenshotShortcut = shortcut
        case .history:
            historyShortcut = shortcut
        }

        return true
    }

    func resetToDefaults() {
        validationMessage = nil
        for action in HotkeyAction.allCases {
            let shortcut = action.defaultShortcut
            persist(shortcut, for: action)

            switch action {
            case .screenshot:
                screenshotShortcut = shortcut
            case .history:
                historyShortcut = shortcut
            }
        }
    }

    func setRegistrationMessage(_ message: String?) {
        registrationMessage = message
    }

    func setRecordingShortcut(_ isRecording: Bool) {
        isRecordingShortcut = isRecording
    }

    private func persist(_ shortcut: HotkeyShortcut, for action: HotkeyAction) {
        guard let data = try? encoder.encode(shortcut) else {
            return
        }
        defaults.set(data, forKey: action.storageKey)
    }

    private static func loadShortcut(for action: HotkeyAction, defaults: UserDefaults) -> HotkeyShortcut {
        guard
            let data = defaults.data(forKey: action.storageKey),
            let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
        else {
            return action.defaultShortcut
        }

        return shortcut
    }
}
