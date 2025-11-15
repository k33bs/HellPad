import Foundation
import Carbon
import AppKit

class HotkeyManager {
    private var hotkeys: [Int: EventHotKeyRef?] = [:]
    private var eventHandler: EventHandlerRef?
    var onHotkeyPressed: ((Int) -> Void)?

    init() {
        setupEventHandler()
    }

    private func setupEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event,
                            EventParamName(kEventParamDirectObject),
                            EventParamType(typeEventHotKeyID),
                            nil,
                            MemoryLayout<EventHotKeyID>.size,
                            nil,
                            &hotkeyID)

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            manager.onHotkeyPressed?(Int(hotkeyID.id))

            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                           callback,
                           1,
                           &eventType,
                           Unmanaged.passUnretained(self).toOpaque(),
                           &eventHandler)
    }

    func registerHotkey(id: Int, keyCode: UInt32, modifiers: UInt32 = 0) {
        let hotkeyID = EventHotKeyID(signature: OSType(0x48425544), // 'HBUD'
                                     id: UInt32(id))
        var hotkeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(keyCode,
                                        modifiers,
                                        hotkeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &hotkeyRef)

        if status == noErr {
            hotkeys[id] = hotkeyRef
        } else {
            print("Failed to register hotkey \(id): \(status)")
        }
    }

    func unregisterHotkey(id: Int) {
        if let hotkeyRef = hotkeys[id], let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeys[id] = nil
        }
    }

    func unregisterAllHotkeys() {
        for (id, _) in hotkeys {
            unregisterHotkey(id: id)
        }
    }

    deinit {
        unregisterAllHotkeys()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }
}
