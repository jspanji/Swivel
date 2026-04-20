import AppKit
import Carbon.HIToolbox

/// Register global keyboard shortcuts via Carbon's `RegisterEventHotKey`.
/// Works system-wide without requiring accessibility permission — unlike
/// `NSEvent.addGlobalMonitorForEvents`, which can't intercept events.
final class HotkeyManager {
    private struct Entry {
        let handler: () -> Void
        let ref: EventHotKeyRef
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    /// Register a global hotkey. Returns a token you can use to unregister.
    /// `keyCode` is a Carbon virtual key (e.g. `kVK_ANSI_1`). `modifiers` is
    /// a Carbon modifier mask (e.g. `cmdKey | optionKey`).
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x45535748 /* 'ESWH' */, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref = ref else { return nil }

        entries[id] = Entry(handler: handler, ref: ref)
        return id
    }

    func unregisterAll() {
        for (_, entry) in entries {
            UnregisterEventHotKey(entry.ref)
        }
        entries.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        entries[id]?.handler()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData, let eventRef = eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { mgr.fire(hotKeyID.id) }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )
    }

    deinit {
        unregisterAll()
    }
}
