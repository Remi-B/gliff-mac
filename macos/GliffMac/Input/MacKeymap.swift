import Carbon.HIToolbox
import Foundation

/// Derives printable XKB symbols from Apple's Unicode layout data. Stock
/// xkeyboard-config Mac variants differ from current macOS Option symbols.
/// Only explicitly supported layouts use this builder; it is not an IME.
enum MacKeymap {
    /// XKB names for the printable evdev positions. Modifiers and editing
    /// keys retain their standard `pc`/`inet(evdev)` definitions.
    static func keyName(_ code: UInt32) -> String? {
        switch code {
        case 2...13: return String(format: "AE%02d", Int(code - 1))
        case 16...27: return String(format: "AD%02d", Int(code - 15))
        case 30...40: return String(format: "AC%02d", Int(code - 29))
        case 44...53: return String(format: "AB%02d", Int(code - 43))
        case 41: return "TLDE"
        case 43: return "BKSL"
        case 57: return "SPCE"
        case 86: return "LSGT"
        default: return nil
        }
    }

    /// A single printable scalar, or one of the dead accents supported by
    /// XKB composition. Multi-scalar text and IME output cannot be sent by
    /// the physical-key protocol and must not be advertised as supported.
    static func symbol(_ text: String, dead: Bool) -> String? {
        if dead {
            return ["`": "dead_grave", "´": "dead_acute", "^": "dead_circumflex",
                    "ˆ": "dead_circumflex", "~": "dead_tilde", "˜": "dead_tilde",
                    "¨": "dead_diaeresis"][text]
        }
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
            scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        return String(format: "U%04X", scalar.value)
    }

    /// `keyboardType` is Carbon's per-device hardware type, not the family
    /// enum: UCKeyTranslate itself handles the ANSI/ISO symbol differences.
    static func overrides(source: TISInputSource, keyboardType: UInt32) -> String? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
            let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let family: KeyCodes.Hardware
        switch KBGetLayoutType(Int16(truncatingIfNeeded: keyboardType)) {
        case UInt32(kKeyboardISO): family = .iso
        case UInt32(kKeyboardJIS): family = .jis
        default: family = .ansi
        }
        var lines: [String] = []
        for mac in KeyCodes.mappedKeyCodes.sorted() {
            guard let evdev = KeyCodes.evdev(mac, hardware: family), let name = keyName(evdev) else { continue }
            var symbols: [String] = []
            // Carbon modifiers are the high byte of EventRecord.modifiers.
            for modifiers: UInt32 in [0, 2, 8, 10] {
                var deadState: UInt32 = 0
                var count = 0
                var chars = [UniChar](repeating: 0, count: 16)
                guard UCKeyTranslate(layout, mac, UInt16(kUCKeyActionDown), modifiers,
                    keyboardType, 0, &deadState, 16, &count, &chars) == noErr else { return nil }
                let dead = deadState != 0
                if dead {
                    // Space completes a dead accent to its spacing form.
                    guard UCKeyTranslate(layout, UInt16(kVK_Space), UInt16(kUCKeyActionDown), 0,
                        keyboardType, 0, &deadState, 16, &count, &chars) == noErr else { return nil }
                }
                guard let symbol = symbol(String(utf16CodeUnits: chars, count: count), dead: dead) else { return nil }
                symbols.append(symbol)
            }
            lines.append("key <\(name)> { [ \(symbols.joined(separator: ", ")) ] };")
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
