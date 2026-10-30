// Export Apple translation data and production XKB maps for Linux validation.
import Carbon.HIToolbox
import Foundation

let properties = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
let sources = TISCreateInputSourceList(properties, true).takeRetainedValue() as! [TISInputSource]
var result: [[String: Any]] = []
for source in sources {
    func string(_ key: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    let id = string(kTISPropertyInputSourceID) ?? ""
    guard KeyboardLayout.supported[id] != nil,
        let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
    let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
    // Apple hardware types: ANSI and ISO. This checks translation data;
    // it does not claim that both physical keyboards have been exercised.
    for keyboardType: UInt32 in [40, 41] {
        var keys: [[String: Any]] = []
        for code in UInt16(0)..<UInt16(128) {
            var values: [String] = []
            for modifiers: UInt32 in [0, 2, 8, 10] {
                var dead: UInt32 = 0
                var count = 0
                var chars = [UniChar](repeating: 0, count: 16)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers,
                    keyboardType, 0, &dead, 16, &count, &chars)
                var text = String(utf16CodeUnits: chars, count: count)
                if dead != 0 {
                    precondition(UCKeyTranslate(layout, UInt16(kVK_Space), UInt16(kUCKeyActionDown), 0,
                        keyboardType, 0, &dead, 16, &count, &chars) == noErr)
                    text = "dead:" + String(utf16CodeUnits: chars, count: count)
                }
                values.append(status == noErr ? text : "error")
            }
            keys.append([
                "mac": Int(code),
                "evdev": Int(KeyCodes.evdev(code, hardware: keyboardType == 41 ? .iso : .ansi) ?? 0),
                "values": values,
            ])
        }
        var remote = KeyboardLayout(sourceID: id, name: id)
        guard let overrides = MacKeymap.overrides(source: source, keyboardType: keyboardType) else {
            fatalError("Cannot derive \(id) for keyboard type \(keyboardType)")
        }
        remote.symbolOverrides = overrides
        result.append([
            "id": id, "keyboardType": keyboardType, "keymap": remote.keymap,
            "name": string(kTISPropertyLocalizedName) ?? id, "keys": keys,
        ])
    }
}
precondition(result.count == KeyboardLayout.supported.count * 2, "Missing supported Apple layouts")
let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(output)
