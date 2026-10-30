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
    private let onFailure: @MainActor () -> Void
    private(set) var failed = false
    private let currentLayout: @MainActor () -> KeyboardLayout
    private let hardware: @MainActor () -> KeyCodes.Hardware
    /// macOS key code → evdev code sent for its press.
    private(set) var pressedKeys: [UInt16: UInt32] = [:]
    private(set) var pressedButtons: Set<UInt32> = []
    private var scrollingAxes: Set<ScrollAxis> = []
    /// The layout whose keymap the remote has, `nil` for the server default.
    private(set) var layout: KeyboardLayout?
    /// Events the session did not accept (queue full or session ended).
    private(set) var dropped = 0

    init(
        layout: KeyboardLayout?,
        currentLayout: @escaping @MainActor () -> KeyboardLayout = KeyboardLayout.current,
        hardware: @escaping @MainActor () -> KeyCodes.Hardware = { KeyCodes.Hardware.current },
        onFailure: @escaping @MainActor () -> Void = {},
        sink: @escaping Sink
    ) {
        self.layout = layout
        self.currentLayout = currentLayout
        self.hardware = hardware
        self.sink = sink
        self.onFailure = onFailure
    }

    // MARK: Keyboard

    /// Sends the current input source's keymap if the remote has another.
    /// Called before each key press and when macOS reports a switch.
    @discardableResult
    func syncLayout() -> KeyboardLayout {
        let current = currentLayout()
        if current.keymap != layout?.keymap {
            guard send(.keymap(keymap: current.keymap)) else { return current }
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
        if send(.key(keycode: code, pressed: true)) { pressedKeys[keyCode] = code }
    }

    // MARK: Pointer

    func move(to point: CGPoint) {
        send(.pointerMotion(x: point.x, y: point.y))
    }

    func button(_ number: Int, pressed: Bool) {
        guard !failed, let button = PointerEvents.evdevButton(number) else { return }
        if pressed {
            guard pressedButtons.insert(button).inserted else { return }
        } else {
            guard pressedButtons.remove(button) != nil else { return }
        }
        send(.pointerButton(button: button, pressed: pressed))
    }

    func scroll(_ events: [InputEvent]) {
        for event in events {
            guard send(event) else { return }
            if case .scroll(let axis, _, let discrete, let stop) = event, discrete == nil {
                if stop { scrollingAxes.remove(axis) } else { scrollingAxes.insert(axis) }
            }
        }
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
        for axis in [ScrollAxis.vertical, .horizontal] where scrollingAxes.contains(axis) {
            send(.scroll(axis: axis, value: 0, discrete: nil, stop: true))
        }
        pressedKeys = [:]
        pressedButtons = []
        scrollingAxes = []
    }

    /// A rejected event breaks ordering (especially a keymap or release).
    /// End this session so the server destroys its virtual input devices and
    /// releases held state; never continue typing with uncertain remote state.
    @discardableResult
    private func send(_ event: InputEvent) -> Bool {
        guard !failed else { return false }
        guard sink(event) else {
            dropped += 1
            failed = true
            pressedKeys = [:]
            pressedButtons = []
            scrollingAxes = []
            onFailure()
            return false
        }
        return true
    }
}
