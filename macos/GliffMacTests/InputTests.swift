import AppKit
import Carbon.HIToolbox
import CoreVideo
import GliffCore
import Testing
@testable import GliffMac

/// Physical key table: positions, the ISO/ANSI swap, modifiers and keys
/// that stay local.
@Suite struct KeyCodeTests {
    @Test func lettersDigitsAndPunctuationFollowPositions() {
        let expected: [(Int, UInt32)] = [
            (kVK_ANSI_Q, 16), (kVK_ANSI_A, 30), (kVK_ANSI_Z, 44), (kVK_ANSI_M, 50), (kVK_ANSI_W, 17),
            (kVK_ANSI_1, 2), (kVK_ANSI_0, 11), (kVK_ANSI_Minus, 12), (kVK_ANSI_Equal, 13),
            (kVK_ANSI_LeftBracket, 26), (kVK_ANSI_Semicolon, 39), (kVK_ANSI_Quote, 40),
            (kVK_ANSI_Backslash, 43), (kVK_ANSI_Comma, 51), (kVK_ANSI_Slash, 53),
            (kVK_Return, 28), (kVK_Delete, 14), (kVK_ForwardDelete, 111), (kVK_Escape, 1),
            (kVK_UpArrow, 103), (kVK_F1, 59), (kVK_F12, 88), (kVK_ANSI_KeypadEnter, 96),
        ]
        for (mac, evdev) in expected {
            #expect(KeyCodes.evdev(UInt16(mac), hardware: .ansi) == evdev, "macOS key \(mac)")
        }
    }

    @Test func modifiersAreLeftAndRightSpecific() {
        let expected: [(Int, UInt32)] = [
            (kVK_Shift, 42), (kVK_RightShift, 54), (kVK_Control, 29), (kVK_RightControl, 97),
            (kVK_Option, 56), (kVK_RightOption, 100), (kVK_Command, 125), (kVK_RightCommand, 126),
            (kVK_CapsLock, 58),
        ]
        for (mac, evdev) in expected {
            #expect(KeyCodes.evdev(UInt16(mac), hardware: .iso) == evdev)
        }
        #expect(Set(KeyCodes.modifierMasks.values).count == 8)
    }

    /// ISO keyboards report the key left of 1 as Section and the one right
    /// of left Shift as Grave; both map by position.
    @Test func isoAndAnsiKeysMapByPosition() {
        let section = UInt16(kVK_ISO_Section), grave = UInt16(kVK_ANSI_Grave)
        #expect(KeyCodes.evdev(section, hardware: .iso) == KeyCodes.keyGrave)
        #expect(KeyCodes.evdev(grave, hardware: .iso) == KeyCodes.key102nd)
        #expect(KeyCodes.evdev(grave, hardware: .ansi) == KeyCodes.keyGrave)
        #expect(KeyCodes.evdev(grave, hardware: .jis) == KeyCodes.keyGrave)
        #expect(KeyCodes.evdev(UInt16(kVK_JIS_Yen), hardware: .jis) == 124)
    }

    @Test func fnAndMediaKeysStayLocal() {
        for key in [kVK_Function, kVK_VolumeUp, kVK_VolumeDown, kVK_Mute, 0x34, 0xFF] {
            #expect(KeyCodes.evdev(UInt16(key), hardware: .ansi) == nil)
        }
    }

    @Test func noTwoKeysShareAnEvdevCode() {
        for hardware in [KeyCodes.Hardware.ansi, .iso] {
            let codes = KeyCodes.mappedKeyCodes.compactMap { KeyCodes.evdev($0, hardware: hardware) }
            #expect(codes.count == KeyCodes.mappedKeyCodes.count)
            #expect(Set(codes).count == codes.count)
            #expect(codes.allSatisfy { (1...255).contains($0) })
        }
    }
}

/// Input sources to XKB layouts and the keymap text.
@Suite struct KeyboardLayoutTests {
    @Test func supportedSourcesSelectTheirLayout() {
        let cases: [(String, String)] = [
            ("com.apple.keylayout.US", "us(mac)"), ("com.apple.keylayout.ABC", "us(mac)"),
            ("com.apple.keylayout.French", "fr(mac)"), ("com.apple.keylayout.French-PC", "fr"),
        ]
        for (source, symbols) in cases {
            let layout = KeyboardLayout(sourceID: source, name: source)
            #expect(layout.isSupported)
            #expect(layout.xkb.symbols == symbols)
            #expect(layout.keymap.contains("include \"pc+\(symbols)+inet(evdev)\""))
        }
        #expect(KeyboardLayout(sourceID: "com.apple.keylayout.French", name: "").keymap
            .contains("evdev+aliases(azerty)"))
    }

    @Test func otherSourcesFallBackToUSVisibly() {
        for source in ["com.apple.keylayout.German", "com.apple.keylayout.French-numerical", ""] {
            let layout = KeyboardLayout(sourceID: source, name: "Other")
            #expect(!layout.isSupported)
            #expect(layout.xkb == .us)
        }
    }

    @Test func theKeymapIsACompleteXKBKeymap() {
        let text = KeyboardLayout.XKB.frenchMac.keymap
        #expect(text.hasPrefix("xkb_keymap {"))
        for section in ["xkb_keycodes", "xkb_types", "xkb_compat", "xkb_symbols"] {
            #expect(text.contains(section))
        }
        #expect(text.hasSuffix("};\n"))
    }

    @Test func unicodeAndDeadSymbolsAreEncodedWithoutXKBInjection() {
        #expect(MacKeymap.symbol("é", dead: false) == "U00E9")
        #expect(MacKeymap.symbol("\"", dead: false) == "U0022")
        #expect(MacKeymap.symbol("^", dead: true) == "dead_circumflex")
        #expect(MacKeymap.symbol("¨", dead: true) == "dead_diaeresis")
        #expect(MacKeymap.symbol("ab", dead: false) == nil)
        #expect(MacKeymap.symbol("?", dead: true) == nil)
    }

    @MainActor @Test func supportedAppleLayoutsDeriveBothHardwareFamilies() throws {
        let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
        var found: Set<String> = []
        for source in sources {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            guard KeyboardLayout.supported[id] != nil else { continue }
            // Apple keyboard types 40 (ANSI), 41 (ISO). No physical hardware
            // is claimed: this verifies Apple's translation data only.
            for type: UInt32 in [40, 41] {
                let text = try #require(MacKeymap.overrides(source: source, keyboardType: type), "\(id) / \(type)")
                #expect(text.contains("key <AD01>"))
                #expect(text.contains("key <TLDE>"))
                if id == "com.apple.keylayout.French" { #expect(text.contains("dead_circumflex")) }
            }
            found.insert(id)
        }
        #expect(found == Set(KeyboardLayout.supported.keys))
    }

    @MainActor @Test func theCurrentSourceIsAKeyboardLayout() {
        let layout = KeyboardLayout.current()
        #expect(!layout.sourceID.isEmpty)
        #expect(!layout.name.isEmpty)
    }
}

/// Points to remote logical coordinates through the renderer's fit.
@Suite struct PointerMappingTests {
    @Test func cornersAndCentreMapThroughLetterboxing() throws {
        // A 1000×600-point view on Retina: the 1920×1080 picture is
        // 2000×1125 pixels at y = 37 (see FrameGeometryTests).
        let mapping = PointerMapping(
            viewSize: CGSize(width: 1000, height: 600), backingScale: 2, frame: FrameGeometry(width: 1920, height: 1080))
        #expect(mapping.fittedRect == CGRect(x: 0, y: 37, width: 2000, height: 1125))
        let topLeft = try #require(mapping.remotePoint(CGPoint(x: 0, y: 18.5)))
        #expect(topLeft == .zero)
        let bottomRight = try #require(mapping.remotePoint(CGPoint(x: 1000, y: 581)))
        #expect(bottomRight == CGPoint(x: 1920, y: 1080))
        let centre = try #require(mapping.remotePoint(CGPoint(x: 500, y: 299.75)))
        #expect(abs(centre.x - 960) < 0.01 && abs(centre.y - 540) < 0.01)
    }

    @Test func theLetterboxAndOutsideClampToTheEdges() throws {
        let mapping = PointerMapping(
            viewSize: CGSize(width: 1000, height: 600), backingScale: 2, frame: FrameGeometry(width: 1920, height: 1080))
        #expect(mapping.remotePoint(CGPoint(x: 500, y: 2)) == CGPoint(x: 960, y: 0))
        #expect(mapping.remotePoint(CGPoint(x: -400, y: 900)) == CGPoint(x: 0, y: 1080))
        #expect(mapping.remotePoint(CGPoint(x: 5000, y: -5000)) == CGPoint(x: 1920, y: 0))
    }

    /// `scale_milli` divides stream pixels into logical ones; Retina only
    /// changes the drawable, not the result.
    @Test func remoteScaleAndBackingScale() throws {
        let frame = FrameGeometry(width: 2560, height: 1600, scaleMilli: 1600)
        for backing in [1.0, 2.0] {
            let mapping = PointerMapping(viewSize: CGSize(width: 1280, height: 800), backingScale: backing, frame: frame)
            #expect(mapping.logicalSize == CGSize(width: 1600, height: 1000))
            let p = try #require(mapping.remotePoint(CGPoint(x: 640, y: 400)))
            #expect(abs(p.x - 800) < 0.01 && abs(p.y - 500) < 0.01)
            #expect(mapping.remotePoint(CGPoint(x: 1280, y: 800)) == CGPoint(x: 1600, y: 1000))
        }
        // 1:1 on Retina: a stream pixel is half a point.
        let exact = PointerMapping(viewSize: CGSize(width: 1280, height: 800), backingScale: 2, frame: frame)
        #expect(exact.pointsPerStreamPixel == 0.5)
    }

    @Test func pillarboxedAndUnscaledPictures() throws {
        let mapping = PointerMapping(
            viewSize: CGSize(width: 1000, height: 1000), backingScale: 1, frame: FrameGeometry(width: 1920, height: 1080))
        #expect(mapping.fittedRect == CGRect(x: 0, y: 218, width: 1000, height: 563))
        let p = try #require(mapping.remotePoint(CGPoint(x: 250, y: 218 + 563.0 / 2)))
        #expect(abs(p.x - 480) < 0.01 && abs(p.y - 540) < 0.01)
    }

    @Test func noPictureNoPoint() {
        let empty = PointerMapping(viewSize: .zero, backingScale: 2, frame: FrameGeometry(width: 1920, height: 1080))
        #expect(empty.remotePoint(.zero) == nil)
        let noStream = PointerMapping(
            viewSize: CGSize(width: 100, height: 100), backingScale: 2, frame: FrameGeometry(width: 0, height: 0))
        #expect(noStream.remotePoint(.zero) == nil)
    }

    @Test func cursorPositionsUseCapturePixelsAcrossStreamDownscaling() throws {
        let mapping = PointerMapping(viewSize: CGSize(width: 1000, height: 600), backingScale: 2,
            frame: FrameGeometry(width: 1920, height: 1080, scaleMilli: 1000))
        // Source is 3840×2160 at scale 2; stream has been downscaled 1/2.
        let point = try #require(mapping.cursorPoint(CGPoint(x: 1920, y: 1080), outputScale: 2))
        #expect(abs(point.x - 500) < 0.001)
        #expect(abs(point.y - 299.75) < 0.001)
        #expect(mapping.cursorPoint(.zero, outputScale: 0) == nil)
        #expect(mapping.cursorPoint(CGPoint(x: Double.nan, y: 0), outputScale: 1) == nil)
    }

    @Test func buttonsAreEvdevCodesNotABitmask() {
        #expect(PointerEvents.evdevButton(0) == 0x110)
        #expect(PointerEvents.evdevButton(1) == 0x111)
        #expect(PointerEvents.evdevButton(2) == 0x112)
        #expect(PointerEvents.evdevButton(3) == 0x113)
        #expect(PointerEvents.evdevButton(4) == 0x114)
        #expect(PointerEvents.evdevButton(7) == 0x117)
        #expect(PointerEvents.evdevButton(8) == nil)
        #expect(PointerEvents.evdevButton(-1) == nil)
    }

    @Test func wheelScrollingSendsDetents() {
        // Wheel up (positive macOS delta) scrolls up: negative on Linux.
        #expect(PointerEvents.scroll(deltaX: 0, deltaY: 1, precise: false, phase: [], momentumPhase: [])
            == [.scroll(axis: .vertical, value: -15, discrete: -1, stop: false)])
        #expect(PointerEvents.scroll(deltaX: -2, deltaY: 0, precise: false, phase: [], momentumPhase: [])
            == [.scroll(axis: .horizontal, value: 30, discrete: 1, stop: false)])
        #expect(PointerEvents.scroll(deltaX: 0, deltaY: 0, precise: false, phase: [], momentumPhase: []).isEmpty)
    }

    @Test func trackpadScrollingSendsFingerDeltasThenStop() {
        #expect(PointerEvents.scroll(deltaX: 3, deltaY: -4.5, precise: true, phase: .changed, momentumPhase: [])
            == [.scroll(axis: .vertical, value: 4.5, discrete: nil, stop: false),
                .scroll(axis: .horizontal, value: -3, discrete: nil, stop: false)])
        let stop: [InputEvent] = [
            .scroll(axis: .vertical, value: 0, discrete: nil, stop: true),
            .scroll(axis: .horizontal, value: 0, discrete: nil, stop: true),
        ]
        #expect(PointerEvents.scroll(deltaX: 0, deltaY: 0, precise: true, phase: .ended, momentumPhase: []) == stop)
        #expect(PointerEvents.scroll(deltaX: 0, deltaY: 0, precise: true, phase: .cancelled, momentumPhase: []) == stop)
        // macOS momentum is dropped: Linux clients scroll on after the stop.
        #expect(PointerEvents.scroll(deltaX: 0, deltaY: 9, precise: true, phase: [], momentumPhase: .changed).isEmpty)
    }
}

/// A layout the test can switch, standing for the selected input source.
@MainActor
final class LayoutSwitch {
    var current = KeyboardLayout(sourceID: "com.apple.keylayout.US", name: "U.S.")
    func select(_ id: String) { current = KeyboardLayout(sourceID: id, name: id) }
}

/// Press/release bookkeeping, layout changes and cleanup.
@MainActor
@Suite struct InputForwarderTests {
    let layouts = LayoutSwitch()
    var sent: [InputEvent] { log.events }
    let log = EventLog()
    let forwarder: InputForwarder

    init() {
        let layouts = layouts, log = log
        forwarder = InputForwarder(
            layout: layouts.current, currentLayout: { layouts.current }, hardware: { .iso }, sink: log.accept)
    }

    @Test func repeatsAndUnpairedReleasesAreDropped() {
        let a = UInt16(kVK_ANSI_A)
        forwarder.keyDown(a, isRepeat: false)
        forwarder.keyDown(a, isRepeat: true)
        forwarder.keyDown(a, isRepeat: false)
        forwarder.keyUp(a)
        forwarder.keyUp(a)
        forwarder.keyUp(UInt16(kVK_ANSI_B))
        forwarder.keyDown(UInt16(kVK_Function), isRepeat: false)
        #expect(sent == [.key(keycode: 30, pressed: true), .key(keycode: 30, pressed: false)])
    }

    @Test func leftAndRightModifiersFollowTheirDeviceBits() {
        let shift = NSEvent.ModifierFlags.shift.rawValue
        forwarder.flagsChanged(UInt16(kVK_Shift), modifierFlags: shift | 0x2)
        forwarder.flagsChanged(UInt16(kVK_RightShift), modifierFlags: shift | 0x2 | 0x4)
        forwarder.flagsChanged(UInt16(kVK_Shift), modifierFlags: shift | 0x4)
        forwarder.flagsChanged(UInt16(kVK_RightShift), modifierFlags: 0)
        forwarder.flagsChanged(UInt16(kVK_RightOption), modifierFlags: 0x40)
        forwarder.flagsChanged(UInt16(kVK_Command), modifierFlags: 0x40 | 0x8)
        forwarder.flagsChanged(UInt16(kVK_Function), modifierFlags: 0x40 | 0x8)
        #expect(sent == [
            .key(keycode: 42, pressed: true), .key(keycode: 54, pressed: true),
            .key(keycode: 42, pressed: false), .key(keycode: 54, pressed: false),
            .key(keycode: 100, pressed: true), .key(keycode: 125, pressed: true),
        ])
    }

    @Test func capsLockTogglesWithAPressAndRelease() {
        forwarder.flagsChanged(UInt16(kVK_CapsLock), modifierFlags: NSEvent.ModifierFlags.capsLock.rawValue)
        forwarder.flagsChanged(UInt16(kVK_CapsLock), modifierFlags: 0)
        #expect(sent == Array(repeating: [.key(keycode: 58, pressed: true), .key(keycode: 58, pressed: false)], count: 2)
            .flatMap { $0 })
        #expect(forwarder.pressedKeys.isEmpty)
    }

    @Test func releaseAllLiftsEveryKeyAndButtonOnce() {
        forwarder.flagsChanged(UInt16(kVK_Command), modifierFlags: 0x8)
        forwarder.keyDown(UInt16(kVK_ISO_Section), isRepeat: false)
        forwarder.button(0, pressed: true)
        forwarder.button(0, pressed: true)
        forwarder.button(3, pressed: true)
        forwarder.releaseAll()
        #expect(sent == [
            .key(keycode: 125, pressed: true), .key(keycode: 41, pressed: true),
            .pointerButton(button: 0x110, pressed: true), .pointerButton(button: 0x113, pressed: true),
            .key(keycode: 41, pressed: false), .key(keycode: 125, pressed: false),
            .pointerButton(button: 0x110, pressed: false), .pointerButton(button: 0x113, pressed: false),
        ])
        log.events = []
        // Nothing is down any more: late releases and a second cleanup send nothing.
        forwarder.keyUp(UInt16(kVK_ISO_Section))
        forwarder.button(0, pressed: false)
        forwarder.releaseAll()
        #expect(sent.isEmpty)
    }

    /// A key typed after a switch to French goes out after French's keymap.
    @Test func aNewLayoutsKeymapPrecedesItsKeys() {
        forwarder.keyDown(UInt16(kVK_ANSI_Q), isRepeat: false)
        layouts.select("com.apple.keylayout.French")
        forwarder.keyUp(UInt16(kVK_ANSI_Q))
        forwarder.keyDown(UInt16(kVK_ANSI_Q), isRepeat: false)
        forwarder.keyDown(UInt16(kVK_ANSI_W), isRepeat: false)
        #expect(sent == [
            .key(keycode: 16, pressed: true), .key(keycode: 16, pressed: false),
            .keymap(keymap: KeyboardLayout.XKB.frenchMac.keymap),
            .key(keycode: 16, pressed: true), .key(keycode: 17, pressed: true),
        ])
        // Two unsupported layouts share the U.S. keymap: no resend between them.
        log.events = []
        layouts.select("com.apple.keylayout.German")
        #expect(forwarder.syncLayout().xkb == .us)
        layouts.select("com.apple.keylayout.Spanish")
        forwarder.syncLayout()
        #expect(sent == [.keymap(keymap: KeyboardLayout.XKB.us.keymap)])
    }

    @Test func releasingDuringAScrollStopsItsActiveAxesOnce() {
        forwarder.scroll([.scroll(axis: .vertical, value: 3, discrete: nil, stop: false)])
        forwarder.releaseAll()
        forwarder.releaseAll()
        #expect(sent == [
            .scroll(axis: .vertical, value: 3, discrete: nil, stop: false),
            .scroll(axis: .vertical, value: 0, discrete: nil, stop: true),
        ])
    }

    @Test func aRejectedKeymapStopsKeysAndCancelsOnce() {
        var failures = 0
        let f = InputForwarder(layout: layouts.current, currentLayout: { self.layouts.current },
            onFailure: { failures += 1 }, sink: log.accept)
        layouts.select("com.apple.keylayout.French")
        log.accepting = false
        f.keyDown(UInt16(kVK_ANSI_A), isRepeat: false)
        log.accepting = true
        f.keyDown(UInt16(kVK_ANSI_B), isRepeat: false)
        f.releaseAll()
        #expect(failures == 1 && f.failed)
        #expect(f.pressedKeys.isEmpty)
        #expect(f.layout?.xkb == .usMac)
        #expect(sent == [.keymap(keymap: KeyboardLayout.XKB.frenchMac.keymap)])
    }

    @Test func aRejectedReleaseStopsTheSession() {
        var failures = 0
        let f = InputForwarder(layout: layouts.current, currentLayout: { self.layouts.current },
            onFailure: { failures += 1 }, sink: log.accept)
        f.keyDown(UInt16(kVK_ANSI_A), isRepeat: false)
        log.accepting = false
        f.releaseAll()
        #expect(failures == 1 && f.failed && f.pressedKeys.isEmpty)
    }

    @Test func refusedEventsAreCounted() {
        log.accepting = false
        forwarder.move(to: CGPoint(x: 1, y: 2))
        forwarder.scroll([.scroll(axis: .vertical, value: 1, discrete: nil, stop: false)])
        #expect(forwarder.dropped == 1)
        #expect(forwarder.failed)
    }
}

@MainActor
final class EventLog {
    var events: [InputEvent] = []
    var accepting = true
    var accept: (InputEvent) -> Bool {
        { [self] event in
            events.append(event)
            return accepting
        }
    }
}

/// Cursor images and the double-cursor policy.
@MainActor
@Suite struct RemoteCursorTests {
    static func shape(_ words: [UInt32], width: UInt32 = 2, height: UInt32 = 2, hot: (Int32, Int32) = (0, 0))
        -> CursorShape
    {
        let bytes = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
        return CursorShape(id: 1, width: width, height: height, hotX: hot.0, hotY: hot.1, argb: Data(bytes))
    }

    @Test func malformedShapesAreRejected() {
        #expect(RemoteCursorImage(Self.shape([0xFF00_0000, 0, 0, 0])) != nil)
        #expect(RemoteCursorImage(Self.shape([0xFF00_0000, 0, 0])) == nil, "short payload")
        #expect(RemoteCursorImage(Self.shape([0, 0, 0, 0], hot: (2, 0))) == nil, "hotspot outside")
        #expect(RemoteCursorImage(Self.shape([0, 0, 0, 0], hot: (0, -1))) == nil)
        #expect(RemoteCursorImage(Self.shape([], width: 0, height: 0)) == nil)
        #expect(RemoteCursorImage(CursorShape(id: 1, width: 2, height: 2, hotX: 0, hotY: 0, argb: nil)) == nil)
    }

    /// Hyprland shares transparent or flat images: no visible shape.
    @Test func transparentAndFlatImagesHaveNoShape() throws {
        let transparent = try #require(RemoteCursorImage(Self.shape([0, 0, 0, 0])))
        let black = try #require(RemoteCursorImage(Self.shape(Array(repeating: 0xFF00_0000, count: 4))))
        let arrow = try #require(RemoteCursorImage(Self.shape([0xFFFF_FFFF, 0xFF00_0000, 0, 0])))
        #expect(!transparent.hasVisibleShape && !black.hasVisibleShape && arrow.hasVisibleShape)
        #expect(RemoteCursor(image: transparent, headless: true) == .hidden)
        #expect(RemoteCursor(image: transparent, headless: false) == .arrow)
        #expect(RemoteCursor(image: nil, headless: false) == .arrow)
        #expect(RemoteCursor(image: arrow, headless: true) == .image(arrow))
    }

    @Test func theCursorIsScaledLikeThePictureWithItsHotspot() throws {
        let image = try #require(RemoteCursorImage(Self.shape(
            Array(repeating: 0xFFFF_FFFF, count: 47) + [0], width: 8, height: 6, hot: (4, 2))))
        let cursor = RemoteCursor.image(image).makeCursor(pointsPerPixel: 0.5)
        #expect(cursor.image.size == NSSize(width: 4, height: 3))
        #expect(cursor.hotSpot == NSPoint(x: 2, y: 1))
        #expect(RemoteCursor.hidden.makeCursor(pointsPerPixel: 1) === RemoteCursor.hiddenCursor)
        #expect(RemoteCursor.arrow.makeCursor(pointsPerPixel: 1) === NSCursor.arrow)
    }
}

/// The surface's AppKit routing: capture click, pointer mapping, the key
/// monitor's filter and the release shortcut.
@MainActor
@Suite(.serialized) struct SurfaceInputTests {
    let window = InputTestWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
        defer: false)
    let surface: RemoteSurface.SurfaceView
    let display = VideoDisplay()
    let log = EventLog()
    let forwarder: InputForwarder

    init() throws {
        window.isReleasedWhenClosed = false
        surface = RemoteSurface.SurfaceView(frame: window.contentLayoutRect)
        window.contentView = surface
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(nil, 800, 600, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attributes as CFDictionary, &buffer)
        // 800×600 stream pixels at scale 2: a 400×300 logical output.
        display.post(DecodedFrame(
            pixelBuffer: try #require(buffer), geometry: FrameGeometry(width: 800, height: 600, scaleMilli: 2000),
            color: .reference, generation: 1, frameID: 1, ptsMicros: 0))
        surface.display = display
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let layouts = LayoutSwitch()
        forwarder = InputForwarder(
            layout: layouts.current, currentLayout: { layouts.current }, hardware: { .ansi }, sink: log.accept)
    }

    func mouse(_ type: NSEvent.EventType, at point: NSPoint, button: Int = 0) -> NSEvent {
        // Window coordinates: origin bottom left; the surface is flipped.
        let location = NSPoint(x: point.x, y: window.contentLayoutRect.height - point.y)
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        if button > 2 {
            return NSEvent(cgEvent: {
                let cg = event.cgEvent!
                cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
                return cg
            }())!
        }
        return event
    }

    func key(_ type: NSEvent.EventType, _ keyCode: Int, flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil)
        -> NSEvent
    {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: (window ?? self.window).windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode))!
    }

    func capture() {
        window.testIsKey = true
        forwarder.activate()
        surface.input = forwarder
        surface.isCapturing = true
        window.makeFirstResponder(surface)
    }

    @Test func theFirstClickCapturesAndIsNotSent() {
        var captured = 0
        surface.onCapture = { captured += 1 }
        surface.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 10, y: 10)))
        surface.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 10, y: 10)))
        #expect(captured == 1)
        #expect(window.firstResponder === surface)
        #expect(log.events.isEmpty)
        window.close()
    }

    @Test func clicksAndDragsMapToTheLogicalOutput() {
        capture()
        surface.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        surface.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 900, y: -40)))
        surface.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 900, y: -40)))
        surface.otherMouseDown(with: mouse(.otherMouseDown, at: NSPoint(x: 0, y: 300), button: 3))
        #expect(log.events == [
            .pointerMotion(x: 200, y: 150), .pointerButton(button: 0x110, pressed: true),
            .pointerMotion(x: 400, y: 0),
            .pointerMotion(x: 400, y: 0), .pointerButton(button: 0x110, pressed: false),
            .pointerMotion(x: 0, y: 300), .pointerButton(button: 0x113, pressed: true),
        ])
        window.close()
    }

    @Test func keysAreTakenOnlyForTheCapturingFirstResponder() {
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered,
            defer: false)
        other.isReleasedWhenClosed = false
        // Not capturing: nothing is consumed.
        #expect(!surface.handleKey(key(.keyDown, kVK_ANSI_A)))
        capture()
        #expect(surface.handleKey(key(.keyDown, kVK_ANSI_A)))
        #expect(surface.handleKey(key(.keyUp, kVK_ANSI_A)))
        #expect(surface.handleKey(key(.keyDown, kVK_ANSI_Q, flags: .command)))
        #expect(!surface.handleKey(key(.keyDown, kVK_ANSI_A, window: other)), "another window's key")
        window.makeFirstResponder(nil)
        #expect(!surface.handleKey(key(.keyDown, kVK_ANSI_B)), "another first responder")
        #expect(log.events == [
            .key(keycode: 30, pressed: true), .key(keycode: 30, pressed: false),
            .key(keycode: 16, pressed: true), .key(keycode: 16, pressed: false),
        ])
        other.close()
        window.close()
    }

    @Test func theReleaseShortcutIsConsumedAndReleasesEverything() {
        var released = 0
        surface.onRelease = {
            released += 1
            self.forwarder.releaseAll()
        }
        capture()
        #expect(surface.handleKey(key(.flagsChanged, kVK_Shift, flags: [.shift, .init(rawValue: 0x2)])))
        #expect(surface.handleKey(key(.keyDown, kVK_Escape, flags: .shift)))
        #expect(released == 1)
        #expect(!surface.isCapturing && surface.input == nil)
        #expect(log.events == [.key(keycode: 42, pressed: true), .key(keycode: 42, pressed: false)])
        // Escape alone, or with other modifiers, is an ordinary key.
        #expect(!Preferences.isReleaseShortcut(keyCode: UInt16(kVK_Escape), modifierFlags: []))
        #expect(!Preferences.isReleaseShortcut(keyCode: UInt16(kVK_Escape), modifierFlags: [.shift, .command]))
        #expect(Preferences.isReleaseShortcut(keyCode: UInt16(kVK_Escape), modifierFlags: [.shift, .capsLock]))
        window.close()
    }

    /// A real AppKit popup enters menu tracking, whose events bypass the
    /// local key monitor. A held key/button must be released without a key-up.
    @Test func openingANativeMenuReleasesHeldInput() {
        var released = 0
        surface.onRelease = { released += 1; self.forwarder.deactivate() }
        capture()
        forwarder.keyDown(UInt16(kVK_ANSI_A), isRepeat: false)
        forwarder.button(0, pressed: true)
        let menu = NSMenu(title: "Input release test")
        let tracking = OSAllocatedUnfairLockCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: menu, queue: nil
        ) { _ in tracking.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        menu.addItem(withTitle: "Local action", action: nil, keyEquivalent: "")
        let cancel = Timer(timeInterval: 0.05, target: menu,
            selector: #selector(NSMenu.cancelTrackingWithoutAnimation), userInfo: nil, repeats: false)
        RunLoop.main.add(cancel, forMode: .eventTracking)
        defer { cancel.invalidate(); window.close() }
        // The popup is intentionally cancelled rather than choosing an item.
        #expect(!menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 100), in: nil))
        #expect(tracking.value == 1, "AppKit actually began native menu tracking")
        #expect(released == 1)
        #expect(!surface.isCapturing && surface.input == nil && !forwarder.isActive)
        #expect(forwarder.pressedKeys.isEmpty && forwarder.pressedButtons.isEmpty)
        #expect(log.events == [
            .key(keycode: 30, pressed: true), .pointerButton(button: 0x110, pressed: true),
            .key(keycode: 30, pressed: false), .pointerButton(button: 0x110, pressed: false),
        ])
    }

    /// Run the actual nested run-loop modes used by controls, window
    /// dragging and modal panels, without calling the key handler ourselves.
    @Test(arguments: [RunLoop.Mode.eventTracking, .modalPanel])
    func nestedLocalTrackingReleasesCapture(_ mode: RunLoop.Mode) {
        surface.onRelease = { self.forwarder.deactivate() }
        capture()
        forwarder.keyDown(UInt16(kVK_ANSI_A), isRepeat: false)
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: mode)
        defer { timer.invalidate(); window.close() }
        RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.1))
        #expect(!surface.isCapturing && surface.input == nil && !forwarder.isActive)
        #expect(forwarder.pressedKeys.isEmpty)
        #expect(log.events == [.key(keycode: 30, pressed: true), .key(keycode: 30, pressed: false)])
    }

    @Test func mappingStaysWithTheDrawnFrameWhileADrawableIsUnavailable() throws {
        let previous = try #require(surface.pointerMapping).frame
        let frame = try #require(display.latest)
        let renderer = try #require(surface.renderer)
        renderer.nextDrawable = { _ in nil }
        display.post(DecodedFrame(pixelBuffer: frame.pixelBuffer,
            geometry: FrameGeometry(width: 400, height: 300, scaleMilli: 1000),
            color: .reference, generation: 2, frameID: 2, ptsMicros: 1))
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(surface.pointerMapping?.frame == previous)
        renderer.nextDrawable = { $0.nextDrawable() }
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(surface.pointerMapping?.frame == display.latest?.geometry)
        window.close()
    }

    @Test func cursorPositionIsDrawnOnlyWhenReleasedAndVisible() throws {
        let image = try #require(RemoteCursorImage(RemoteCursorTests.shape(
            [0xFFFF_FFFF, 0xFF00_0000, 0, 0], hot: (1, 1))))
        surface.remoteCursor = .image(image)
        surface.cursorOutputScale = 2
        surface.cursorPosition = CursorPosition(x: 200, y: 100, shapeId: 1, visible: true)
        #expect(surface.cursorOverlayFrame == CGRect(x: 99.5, y: 49.5, width: 1, height: 1))
        capture()
        #expect(surface.cursorOverlayFrame == nil, "NSCursor owns the image during capture")
        surface.stopCapture()
        #expect(surface.cursorOverlayFrame != nil)
        surface.cursorPosition = CursorPosition(x: 200, y: 100, shapeId: 1, visible: false)
        #expect(surface.cursorOverlayFrame == nil)
        surface.cursorPosition = CursorPosition(x: 200, y: 100, shapeId: 2, visible: true)
        #expect(surface.cursorOverlayFrame != nil, "location survives a shape association change")
        surface.cursorPosition = CursorPosition(x: 200, y: 100, shapeId: 1, visible: true)
        surface.display = nil
        #expect(surface.cursorOverlayFrame == nil)
        window.close()
    }

    @Test func aShapeOnlyUpdateKeepsTheLastVisiblePosition() throws {
        let oldImage = try #require(RemoteCursorImage(RemoteCursorTests.shape(
            [0xFFFF_FFFF, 0xFF00_0000, 0, 0], hot: (1, 1))))
        surface.remoteCursor = .image(oldImage)
        surface.cursorOutputScale = 2
        let position = CursorPosition(x: 200, y: 100, shapeId: 1, visible: true)
        surface.cursorPosition = position
        #expect(surface.cursorOverlayFrame == CGRect(x: 99.5, y: 49.5, width: 1, height: 1))
        var nextImage = oldImage
        nextImage.id = 2
        nextImage.hotX = 0
        nextImage.hotY = 0
        // Server may send only this shape and coalesce queued position events.
        surface.remoteCursor = .image(nextImage)
        #expect(surface.cursorPosition == position, "shape must not alter location or visibility")
        #expect(surface.cursorOverlayFrame == CGRect(x: 100, y: 50, width: 1, height: 1))
        window.close()
    }

    @Test func detachedSurfaceReleasesHeldInput() {
        capture()
        forwarder.keyDown(UInt16(kVK_ANSI_A), isRepeat: false)
        window.contentView = NSView()
        #expect(!surface.isCapturing && surface.input == nil)
        #expect(forwarder.pressedKeys.isEmpty)
        #expect(log.events.suffix(1) == [.key(keycode: 30, pressed: false)])
        window.close()
    }

    @Test func aReleasedForwarderDoesNotSwallowLocalKeysBeforeTheViewUpdates() {
        capture()
        forwarder.deactivate()
        #expect(!surface.handleKey(key(.keyDown, kVK_ANSI_Q, flags: .command)))
        surface.mouseDown(with: mouse(.leftMouseDown, at: .zero))
        #expect(log.events.isEmpty)
        window.close()
    }

    @Test func inactiveWindowCannotForwardPointerOrKeys() {
        capture()
        window.testIsKey = false
        // A stale SwiftUI input value must not reactivate event routing.
        surface.input = forwarder
        surface.isCapturing = true
        surface.mouseDown(with: mouse(.leftMouseDown, at: .zero))
        #expect(!surface.handleKey(key(.keyDown, kVK_ANSI_A)))
        #expect(log.events.isEmpty)
        window.close()
    }

    @Test func losingFirstResponderReleasesCapture() {
        var released = 0
        surface.onRelease = { released += 1 }
        capture()
        window.makeFirstResponder(nil)
        #expect(released == 1)
        #expect(!surface.isCapturing)
        window.close()
    }
}

/// Deterministic key-window state without stealing desktop focus in CI.
@MainActor
final class InputTestWindow: NSWindow {
    var testIsKey = true
    override var isKeyWindow: Bool { testIsKey }
}
