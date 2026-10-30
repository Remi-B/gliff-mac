import AppKit
import Carbon.HIToolbox
import GliffCore
import os

/// Turns one session's captured macOS input into protocol input events.
///
/// It remembers what the remote holds down, so every press gets exactly one
/// release: auto-repeat is dropped (the remote compositor repeats on its
/// own), releases of keys or buttons whose press was not sent are dropped,
/// and `releaseAll` lifts whatever is still down when capture ends, focus
/// moves or the session changes. Before a key press it makes sure the
/// remote has the keymap of the current input source.
@MainActor
final class InputForwarder {
    /// Queues one event for the server; false when it was not accepted.
    typealias Sink = (InputEvent) -> Bool

    private let sink: Sink
    private let currentLayout: @MainActor () -> KeyboardLayout
    private let hardware: @MainActor () -> KeyCodes.Hardware
    /// macOS key code → evdev code sent for its press.
    private(set) var pressedKeys: [UInt16: UInt32] = [:]
    private(set) var pressedButtons: Set<UInt32> = []
    /// The layout whose keymap the remote has, `nil` for the server default.
    private(set) var layout: KeyboardLayout?
    /// Events the session did not accept (queue full or session ended).
    private(set) var dropped = 0

    init(
        layout: KeyboardLayout?,
        currentLayout: @escaping @MainActor () -> KeyboardLayout = KeyboardLayout.current,
        hardware: @escaping @MainActor () -> KeyCodes.Hardware = { KeyCodes.Hardware.current },
        sink: @escaping Sink
    ) {
        self.layout = layout
        self.currentLayout = currentLayout
        self.hardware = hardware
        self.sink = sink
    }

    // MARK: Keyboard

    /// Sends the current input source's keymap if the remote has another.
    /// Called before each key press and when macOS reports a switch.
    @discardableResult
    func syncLayout() -> KeyboardLayout {
        let current = currentLayout()
        if current.keymap != layout?.keymap {
            send(.keymap(keymap: current.keymap))
        }
        layout = current
        return current
    }

    func keyDown(_ keyCode: UInt16, isRepeat: Bool) {
        guard !isRepeat, pressedKeys[keyCode] == nil,
            let code = KeyCodes.evdev(keyCode, hardware: hardware())
        else { return }
        syncLayout()
        press(keyCode, code)
    }

    func keyUp(_ keyCode: UInt16) {
        guard let code = pressedKeys.removeValue(forKey: keyCode) else { return }
        send(.key(keycode: code, pressed: false))
    }

    /// A modifier changed. Left and right keys are told apart by their
    /// device bits in `modifierFlags`; Caps Lock reports each toggle once,
    /// so it is a full press and release on the remote; Fn stays local.
    func flagsChanged(_ keyCode: UInt16, modifierFlags: UInt) {
        if Int(keyCode) == kVK_CapsLock {
            syncLayout()
            send(.key(keycode: KeyCodes.keyCapsLock, pressed: true))
            send(.key(keycode: KeyCodes.keyCapsLock, pressed: false))
            return
        }
        guard let mask = KeyCodes.modifierMasks[keyCode],
            let code = KeyCodes.evdev(keyCode, hardware: hardware())
        else { return }
        let down = modifierFlags & mask != 0
        if down, pressedKeys[keyCode] == nil {
            syncLayout()
            press(keyCode, code)
        } else if !down {
            keyUp(keyCode)
        }
    }

    private func press(_ keyCode: UInt16, _ code: UInt32) {
        pressedKeys[keyCode] = code
        send(.key(keycode: code, pressed: true))
    }

    // MARK: Pointer

    func move(to point: CGPoint) {
        send(.pointerMotion(x: point.x, y: point.y))
    }

    func button(_ number: Int, pressed: Bool) {
        guard let button = PointerEvents.evdevButton(number) else { return }
        if pressed {
            guard pressedButtons.insert(button).inserted else { return }
        } else {
            guard pressedButtons.remove(button) != nil else { return }
        }
        send(.pointerButton(button: button, pressed: pressed))
    }

    func scroll(_ events: [InputEvent]) {
        events.forEach(send)
    }

    // MARK: Release

    /// Releases every key and button the remote holds from this client.
    func releaseAll() {
        for code in pressedKeys.values.sorted() {
            send(.key(keycode: code, pressed: false))
        }
        for button in pressedButtons.sorted() {
            send(.pointerButton(button: button, pressed: false))
        }
        pressedKeys = [:]
        pressedButtons = []
    }

    private func send(_ event: InputEvent) {
        if !sink(event) { dropped += 1 }
    }
}
