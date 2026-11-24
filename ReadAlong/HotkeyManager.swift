import AppKit
import Carbon

/// Registers the global start/stop shortcut. Carbon hot keys need no extra permission.
@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: @MainActor () -> Void

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    @discardableResult
    func register(keyCode: UInt32 = AppSettings.standard.hotkeyCode, modifiers: UInt32 = AppSettings.standard.hotkeyModifiers) -> OSStatus {
        guard hotKeyRef == nil else { return noErr }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<HotkeyManager>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                        .handlePress()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x52444C47), id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    /// Rebinds the global shortcut after the user records a new one.
    func reregister(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        unregister()
        return register(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - Display and conversion helpers

    /// Carbon modifiers for RegisterEventHotKey from AppKit modifier flags.
    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// Human form like "⌥⌘R" for the setup window. shortcut: en-US
    /// layout only; unmapped keys display as "Key <code>".
    nonisolated static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var glyphs = ""
        if modifiers & UInt32(shiftKey) != 0 { glyphs += "⇧" }
        if modifiers & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { glyphs += "⌥" }
        if modifiers & UInt32(cmdKey) != 0 { glyphs += "⌘" }
        return glyphs + (keyLabels[keyCode] ?? "Key \(keyCode)")
    }

    private nonisolated static let keyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_ANSI_X): "X", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_L): "L", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_Space): "Space",
    ]

    private nonisolated static func keyLabel(_ keyCode: UInt32) -> String? {
        keyLabels[keyCode]
    }

    private func handlePress() {
        Log.note("hotkey pressed")
        onPress()
    }
}
