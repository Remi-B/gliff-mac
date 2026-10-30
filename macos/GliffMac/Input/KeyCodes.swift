import AppKit
import Carbon.HIToolbox

/// Physical macOS keys as Linux evdev key codes (`KEY_*` in
/// `linux/input-event-codes.h`).
///
/// macOS virtual key codes name positions on the ANSI US keyboard, whatever
/// the input source, so the table is layout independent: the remote's keymap
/// gives each key its symbols. Two positions depend on the hardware: on ISO
/// keyboards macOS reports the key left of 1 as `kVK_ISO_Section` and the key
/// right of the left Shift as `kVK_ANSI_Grave`; on ANSI keyboards it is the
/// other way round (the latter key does not exist). Both follow the position,
/// as Linux does: left of 1 is `KEY_GRAVE`, right of left Shift `KEY_102ND`.
enum KeyCodes {
    /// The hardware family of the keyboard that sent the last event.
    enum Hardware: Equatable, Sendable {
        case ansi, iso, jis

        /// From the keyboard type of the last key event (Carbon).
        static var current: Hardware {
            switch KBGetLayoutType(Int16(LMGetKbdType())) {
            case UInt32(kKeyboardISO): .iso
            case UInt32(kKeyboardJIS): .jis
            default: .ansi
            }
        }
    }

    /// The evdev code of `keyCode`, or `nil` for keys that stay local:
    /// Fn/Globe and the media keys (volume and mute), which control the Mac.
    static func evdev(_ keyCode: UInt16, hardware: Hardware) -> UInt32? {
        switch Int(keyCode) {
        case kVK_ISO_Section: hardware == .iso ? keyGrave : key102nd
        case kVK_ANSI_Grave: hardware == .iso ? key102nd : keyGrave
        default: table[keyCode]
        }
    }

    static let keyGrave: UInt32 = 41
    static let key102nd: UInt32 = 86
    static let keyEscape: UInt32 = 1
    static let keyCapsLock: UInt32 = 58

    /// Modifier keys and the device-dependent `modifierFlags` bit that is set
    /// while each one is down (`NX_DEVICE*KEYMASK` in IOKit's `IOLLEvent.h`),
    /// so left and right keys are told apart in `flagsChanged`.
    static let modifierMasks: [UInt16: UInt] = [
        UInt16(kVK_Control): 0x0001,
        UInt16(kVK_Shift): 0x0002,
        UInt16(kVK_RightShift): 0x0004,
        UInt16(kVK_Command): 0x0008,
        UInt16(kVK_RightCommand): 0x0010,
        UInt16(kVK_Option): 0x0020,
        UInt16(kVK_RightOption): 0x0040,
        UInt16(kVK_RightControl): 0x2000,
    ]

    /// Every key but the two hardware-dependent ones.
    private static let table: [UInt16: UInt32] = {
        let pairs: [(Int, UInt32)] = [
            // Letters.
            (kVK_ANSI_A, 30), (kVK_ANSI_B, 48), (kVK_ANSI_C, 46), (kVK_ANSI_D, 32),
            (kVK_ANSI_E, 18), (kVK_ANSI_F, 33), (kVK_ANSI_G, 34), (kVK_ANSI_H, 35),
            (kVK_ANSI_I, 23), (kVK_ANSI_J, 36), (kVK_ANSI_K, 37), (kVK_ANSI_L, 38),
            (kVK_ANSI_M, 50), (kVK_ANSI_N, 49), (kVK_ANSI_O, 24), (kVK_ANSI_P, 25),
            (kVK_ANSI_Q, 16), (kVK_ANSI_R, 19), (kVK_ANSI_S, 31), (kVK_ANSI_T, 20),
            (kVK_ANSI_U, 22), (kVK_ANSI_V, 47), (kVK_ANSI_W, 17), (kVK_ANSI_X, 45),
            (kVK_ANSI_Y, 21), (kVK_ANSI_Z, 44),
            // Digit row.
            (kVK_ANSI_1, 2), (kVK_ANSI_2, 3), (kVK_ANSI_3, 4), (kVK_ANSI_4, 5),
            (kVK_ANSI_5, 6), (kVK_ANSI_6, 7), (kVK_ANSI_7, 8), (kVK_ANSI_8, 9),
            (kVK_ANSI_9, 10), (kVK_ANSI_0, 11), (kVK_ANSI_Minus, 12), (kVK_ANSI_Equal, 13),
            // Punctuation.
            (kVK_ANSI_LeftBracket, 26), (kVK_ANSI_RightBracket, 27), (kVK_ANSI_Semicolon, 39),
            (kVK_ANSI_Quote, 40), (kVK_ANSI_Backslash, 43), (kVK_ANSI_Comma, 51),
            (kVK_ANSI_Period, 52), (kVK_ANSI_Slash, 53),
            // Editing and whitespace.
            (kVK_Escape, 1), (kVK_Delete, 14), (kVK_Tab, 15), (kVK_Return, 28),
            (kVK_Space, 57), (kVK_ForwardDelete, 111), (kVK_Help, 110),
            (kVK_Home, 102), (kVK_End, 107), (kVK_PageUp, 104), (kVK_PageDown, 109),
            (kVK_LeftArrow, 105), (kVK_RightArrow, 106), (kVK_UpArrow, 103), (kVK_DownArrow, 108),
            (kVK_ContextualMenu, 127),
            // Modifiers: Control, Shift, Option as Alt, Command as Super.
            (kVK_Control, 29), (kVK_RightControl, 97), (kVK_Shift, 42), (kVK_RightShift, 54),
            (kVK_Option, 56), (kVK_RightOption, 100), (kVK_Command, 125), (kVK_RightCommand, 126),
            (kVK_CapsLock, 58),
            // Function keys; F13-F15 are Print Screen, Scroll Lock and Pause
            // on PC keyboards attached to a Mac.
            (kVK_F1, 59), (kVK_F2, 60), (kVK_F3, 61), (kVK_F4, 62), (kVK_F5, 63),
            (kVK_F6, 64), (kVK_F7, 65), (kVK_F8, 66), (kVK_F9, 67), (kVK_F10, 68),
            (kVK_F11, 87), (kVK_F12, 88), (kVK_F13, 183), (kVK_F14, 184), (kVK_F15, 185),
            (kVK_F16, 186), (kVK_F17, 187), (kVK_F18, 188), (kVK_F19, 189), (kVK_F20, 190),
            // Keypad; Clear sits where Num Lock does, as HID reports it.
            (kVK_ANSI_Keypad0, 82), (kVK_ANSI_Keypad1, 79), (kVK_ANSI_Keypad2, 80),
            (kVK_ANSI_Keypad3, 81), (kVK_ANSI_Keypad4, 75), (kVK_ANSI_Keypad5, 76),
            (kVK_ANSI_Keypad6, 77), (kVK_ANSI_Keypad7, 71), (kVK_ANSI_Keypad8, 72),
            (kVK_ANSI_Keypad9, 73), (kVK_ANSI_KeypadDecimal, 83), (kVK_ANSI_KeypadMultiply, 55),
            (kVK_ANSI_KeypadPlus, 78), (kVK_ANSI_KeypadMinus, 74), (kVK_ANSI_KeypadDivide, 98),
            (kVK_ANSI_KeypadEnter, 96), (kVK_ANSI_KeypadEquals, 117), (kVK_ANSI_KeypadClear, 69),
            // JIS: Yen, Ro, keypad comma, Eisu (HID LANG2) and Kana (LANG1).
            (kVK_JIS_Yen, 124), (kVK_JIS_Underscore, 89), (kVK_JIS_KeypadComma, 95),
            (kVK_JIS_Eisu, 123), (kVK_JIS_Kana, 122),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { (UInt16($0.0), $0.1) })
    }()

    /// Every mapped macOS key code, for tests.
    static var mappedKeyCodes: [UInt16] {
        Array(table.keys) + [UInt16(kVK_ISO_Section), UInt16(kVK_ANSI_Grave)]
    }
}
