import Carbon
import Foundation

@MainActor
final class GlobalHotKeyCenter {
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef?] = [:]
    private var handlers: [UInt32: () -> Void] = [:]

    init() {
        installHandler()
    }

    deinit {
        for ref in hotKeyRefs.values {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> OSStatus {
        unregister(id: id)

        let hotKeyID = EventHotKeyID(signature: fourCharCode("Stbd"), id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            handlers[id] = handler
            hotKeyRefs[id] = hotKeyRef
        }

        return status
    }

    func unregister(id: UInt32) {
        if let hotKeyRef = hotKeyRefs.removeValue(forKey: id) ?? nil {
            UnregisterEventHotKey(hotKeyRef)
        }
        handlers.removeValue(forKey: id)
    }

    private func installHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard
                    let userData,
                    let event
                else {
                    return noErr
                }

                let center = Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                center.handlers[hotKeyID.id]?()
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf16.reduce(0) { partialResult, character in
        (partialResult << 8) + OSType(character)
    }
}
