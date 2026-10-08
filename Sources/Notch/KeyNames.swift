import Carbon.HIToolbox
import Foundation
import NotchCore

enum KeyNames {
    private static let nonPrintingKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        76: "↩", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 109: "F10",
        111: "F12", 117: "⌦", 118: "F4", 120: "F2",
        122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static func display(keyCode: UInt32) -> String {
        let code = UInt16(truncatingIfNeeded: keyCode)
        if let name = nonPrintingKeys[code] { return name }
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "Key \(keyCode)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length: UInt = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let result = characters.withUnsafeMutableBufferPointer { buffer in
            UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                           buffer.count, &length, buffer.baseAddress!)
        }
        guard result == noErr, length > 0 else { return "Key \(keyCode)" }
        let name = String(utf16CodeUnits: characters, count: Int(length)).uppercased()
        return name.isEmpty ? "Key \(keyCode)" : name
    }

    static func shortcutName(for spec: HotKeySpec) -> String {
        var result = ""
        if spec.carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if spec.carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if spec.carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if spec.carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + display(keyCode: spec.keyCode)
    }
}
