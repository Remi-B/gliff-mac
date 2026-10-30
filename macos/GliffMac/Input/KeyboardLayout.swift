import Carbon.HIToolbox
import Foundation

/// The local keyboard layout and the XKB keymap the remote should use for it.
///
/// Keys travel as physical evdev codes; the server's virtual keyboard turns
/// them into symbols with the keymap the client sends (`Hello`, then
/// `Keymap` on each change). Parity therefore depends on an XKB layout that
/// matches the macOS input source. Only the sources listed in `supported`
/// have one; any other falls back to U.S. and says so (`isSupported`).
///
/// The keymap is XKB text that includes xkeyboard-config components by name,
/// as `setxkbmap -print` writes it; the server and Hyprland compile it with
/// their own xkeyboard-config. Option is Alt and Command is Super; the right
/// Option key chooses the third level (AltGr) in every supported layout, so
/// the left Option key keeps Alt shortcuts. Dead keys are the remote's.
struct KeyboardLayout: Equatable, Sendable {
    /// The XKB layout (and variant) standing for a macOS input source.
    struct XKB: Equatable, Sendable {
        var layout: String
        var variant: String
        /// Name of the evdev key code aliases: `azerty` for AZERTY layouts.
        var aliases: String
        var description: String

        var symbols: String { variant.isEmpty ? layout : "\(layout)(\(variant))" }

        /// Complete `xkb_keymap` text (format v1) built from components.
        var keymap: String {
            """
            xkb_keymap {
            \txkb_keycodes  { include "evdev+aliases(\(aliases))" };
            \txkb_types     { include "complete" };
            \txkb_compat    { include "complete" };
            \txkb_symbols   { include "pc+\(symbols)+inet(evdev)" };
            };

            """
        }

        static let usMac = XKB(layout: "us", variant: "mac", aliases: "qwerty", description: "U.S. (Macintosh)")
        static let us = XKB(layout: "us", variant: "", aliases: "qwerty", description: "U.S.")
        static let frenchMac = XKB(layout: "fr", variant: "mac", aliases: "azerty", description: "French (Macintosh)")
        static let frenchPC = XKB(layout: "fr", variant: "", aliases: "azerty", description: "French (PC)")
    }

    /// The macOS input source ID, for example `com.apple.keylayout.French`.
    var sourceID: String
    /// The input source's localized name, for the status bar.
    var name: String
    /// The XKB layout sent to the remote: the supported match, or U.S.
    var xkb: XKB
    var isSupported: Bool

    init(sourceID: String, name: String) {
        self.sourceID = sourceID
        self.name = name
        let match = Self.supported[sourceID]
        xkb = match ?? Self.fallback
        isSupported = match != nil
    }

    /// Printable symbols derived from the supported macOS source.
    var symbolOverrides = ""
    var keymap: String {
        guard !symbolOverrides.isEmpty else { return xkb.keymap }
        return xkb.keymap.replacingOccurrences(
            of: "include \"pc+\(xkb.symbols)+inet(evdev)\"",
            with: "include \"pc+\(xkb.symbols)+inet(evdev)+level3(ralt_switch)\"\n\(symbolOverrides)")
    }

    /// Supported Apple sources. The XKB variant supplies standard behavior;
    /// MacKeymap overrides printable symbols with the actual Apple data.
    static let supported: [String: XKB] = [
        "com.apple.keylayout.US": .usMac,
        "com.apple.keylayout.ABC": .usMac,
        "com.apple.keylayout.French": .frenchMac,
        "com.apple.keylayout.French-PC": .frenchPC,
    ]

    /// Sent for every other source: the server's own default layout.
    static let fallback = XKB.us

    /// Layouts and hardware types are cached; source IDs outside the
    /// supported set (including input methods) visibly fall back to U.S.
    @MainActor private static var cache: [String: KeyboardLayout] = [:]

    @MainActor static func current() -> KeyboardLayout {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return KeyboardLayout(sourceID: "", name: "Unknown")
        }
        func string(_ key: CFString) -> String? {
            guard let value = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        }
        let id = string(kTISPropertyInputSourceID) ?? ""
        let type = UInt32(LMGetKbdType())
        let cacheKey = "\(id):\(type)"
        if let cached = cache[cacheKey] { return cached }
        var result = KeyboardLayout(sourceID: id, name: string(kTISPropertyLocalizedName) ?? id)
        if result.isSupported {
            if let overrides = MacKeymap.overrides(source: source, keyboardType: type) {
                result.symbolOverrides = overrides
            } else {
                // Never silently claim parity when derivation failed.
                result.isSupported = false
                result.xkb = fallback
            }
        }
        cache[cacheKey] = result
        return result
    }

    /// Posted by macOS when the selected keyboard input source changes.
    static let selectionChanged = Notification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String)
}
