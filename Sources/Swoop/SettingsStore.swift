import AppKit
import Carbon.HIToolbox
import Combine
import SwoopCore

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private static let defaultsKey = "settings"

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        } else {
            settings = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

enum KeyNames {
    private static let special: [Int: String] = [
        KeyCode.tab: "Tab", KeyCode.return: "Return", KeyCode.keypadEnter: "Enter",
        KeyCode.escape: "Esc", KeyCode.delete: "Delete", 49: "Space", 117: "Forward Delete",
        KeyCode.left: "←", KeyCode.right: "→", KeyCode.up: "↑", KeyCode.down: "↓",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func name(_ keyCode: Int?) -> String {
        guard let keyCode else { return "None" }
        return special[keyCode] ?? character(keyCode, shifted: false)?.uppercased() ?? "Key \(keyCode)"
    }

    /// What the key types on the current keyboard layout, ignoring every modifier but shift.
    static func character(_ keyCode: Int, shifted: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let modifierState = shifted ? UInt32(shiftKey >> 8) : 0
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), modifierState, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
