import AppKit
import Carbon.HIToolbox

/// Global summon hotkey via Carbon's `RegisterEventHotKey` — the one global
/// hotkey API that needs no Accessibility/Input Monitoring permission.
///
/// The combo comes from settings.json (`"hotkey": "option+space"`); an
/// unparseable spec falls back to the ⌥Space default so the app is never
/// summonless. Note: another app holding the same combo through a CGEvent
/// tap (e.g. ChatGPT's launcher) wins regardless of registration order.
enum HotKey {
    static let defaultSpec = "option+space"

    nonisolated(unsafe) private static var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private static var handlerRef: EventHandlerRef?
    nonisolated(unsafe) static var onPress: (@MainActor () -> Void)?

    static func register(spec: String = defaultSpec) {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C callback — no captures allowed; dispatches to the static handler.
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.onPress?() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let combo = parse(spec) ?? {
            NSLog("pultik: unparseable hotkey %@ — falling back to %@", spec, defaultSpec)
            return parse(defaultSpec)!
        }()

        let hotKeyID = EventHotKeyID(signature: OSType(0x504C_544B) /* 'PLTK' */, id: 1)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("pultik: RegisterEventHotKey failed (%d)", status)
        }
    }

    // MARK: - Spec parsing ("cmd+option+space", "control+p", …)

    private static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var key: String?
        for token in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "option", "opt", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "control", "ctrl", "⌃": modifiers |= UInt32(controlKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            default:
                guard key == nil else { return nil } // two non-modifier tokens
                key = token
            }
        }
        // A global hotkey without modifiers would eat plain typing.
        guard let key, modifiers != 0, let keyCode = keyCodes[key] else { return nil }
        return (keyCode, modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab),
        "escape": UInt32(kVK_Escape), "`": UInt32(kVK_ANSI_Grave),
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
    ]
}
