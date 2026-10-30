import AppKit
import GliffCore

/// Maps surface points to the remote output's logical coordinates.
///
/// The renderer draws the picture into `FrameGeometry.fit(in:)` of a
/// drawable of `bounds × backing scale` pixels, rounded. Pointer mapping
/// inverts exactly that: view points → drawable pixels → position within
/// the fitted rectangle → stream pixels → logical pixels (stream pixels ÷
/// `scale_milli`/1000, which already folds in any server downscale). Points
/// in the letterbox or outside the view are clamped to the picture's edge,
/// so a drag that leaves the window ends on the remote border.
struct PointerMapping: Equatable {
    /// The surface size in points.
    var viewSize: CGSize
    /// Backing pixels per point (2 on Retina displays).
    var backingScale: CGFloat
    /// The geometry of the picture on screen.
    var frame: FrameGeometry

    /// The drawable size, as the surface sizes its Metal layer.
    var drawableSize: CGSize {
        CGSize(width: (viewSize.width * backingScale).rounded(), height: (viewSize.height * backingScale).rounded())
    }

    /// The picture's rectangle in drawable pixels.
    var fittedRect: CGRect { frame.fit(in: drawableSize) }

    /// Stream pixels per logical remote pixel.
    var remoteScale: Double { max(Double(frame.scaleMilli), 1) / 1000 }

    /// The remote output's logical size.
    var logicalSize: CGSize {
        CGSize(width: Double(frame.width) / remoteScale, height: Double(frame.height) / remoteScale)
    }

    /// Screen points per stream pixel: how large remote pixels appear.
    var pointsPerStreamPixel: CGFloat {
        let rect = fittedRect
        guard frame.width > 0, backingScale > 0, rect.width > 0 else { return 1 / max(backingScale, 1) }
        return rect.width / CGFloat(frame.width) / backingScale
    }

    /// Capture-buffer pixels to surface points. CursorPos is in the full
    /// capture buffer's coordinates, not the downscaled H.264 stream.
    func cursorPoint(_ point: CGPoint, outputScale: CGFloat) -> CGPoint? {
        let rect = fittedRect
        guard rect.width > 0, rect.height > 0, outputScale > 0,
            point.x.isFinite, point.y.isFinite else { return nil }
        let ratio = CGFloat(remoteScale) / outputScale
        return CGPoint(
            x: (rect.minX + point.x * ratio * rect.width / CGFloat(frame.width)) / backingScale,
            y: (rect.minY + point.y * ratio * rect.height / CGFloat(frame.height)) / backingScale)
    }

    /// `point` in a flipped view (origin top left) as remote logical
    /// coordinates, clamped to the output; `nil` before there is a picture.
    func remotePoint(_ point: CGPoint) -> CGPoint? {
        let rect = fittedRect
        guard rect.width > 0, rect.height > 0, backingScale > 0 else { return nil }
        let u = ((point.x * backingScale - rect.minX) / rect.width).clamped(to: 0...1)
        let v = ((point.y * backingScale - rect.minY) / rect.height).clamped(to: 0...1)
        let size = logicalSize
        return CGPoint(x: u * size.width, y: v * size.height)
    }
}

/// Pointer buttons and scrolling with Linux semantics.
enum PointerEvents {
    static let buttonLeft: UInt32 = 0x110
    static let buttonRight: UInt32 = 0x111
    static let buttonMiddle: UInt32 = 0x112
    static let buttonSide: UInt32 = 0x113
    static let buttonExtra: UInt32 = 0x114
    static let buttonTask: UInt32 = 0x117

    /// `NSEvent.buttonNumber` as an evdev `BTN_*` code: 0 left, 1 right,
    /// 2 middle, 3 back (`BTN_SIDE`), 4 forward (`BTN_EXTRA`), then
    /// `BTN_FORWARD`, `BTN_BACK` and `BTN_TASK`; higher buttons are not sent.
    static func evdevButton(_ number: Int) -> UInt32? {
        switch number {
        case 0: buttonLeft
        case 1: buttonRight
        case 2: buttonMiddle
        case 3...7: buttonSide + UInt32(number - 3)
        default: nil
        }
    }

    /// One wheel detent, in logical pixels, as upstream's client sends it.
    static let pixelsPerDetent = 15.0

    /// A macOS scroll event as Wayland axis events, positive down and right.
    ///
    /// The deltas keep the direction the user chose on the Mac (natural
    /// scrolling or not). A mouse wheel sends `discrete` detents. A trackpad
    /// or Magic Mouse sends finger deltas in points and a stop when the
    /// fingers lift; macOS momentum events are dropped, since Linux clients
    /// scroll kinetically after the stop themselves.
    static func scroll(
        deltaX: Double, deltaY: Double, precise: Bool, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase
    ) -> [InputEvent] {
        if !momentumPhase.isEmpty { return [] }
        var events: [InputEvent] = []
        for (axis, delta) in [(ScrollAxis.vertical, -deltaY), (.horizontal, -deltaX)] where delta != 0 {
            if precise {
                events.append(.scroll(axis: axis, value: delta, discrete: nil, stop: false))
            } else {
                let detents = Int32(delta.sign == .minus ? -1 : 1)
                events.append(.scroll(axis: axis, value: delta * pixelsPerDetent, discrete: detents, stop: false))
            }
        }
        if precise, !phase.isDisjoint(with: [.ended, .cancelled]) {
            events.append(.scroll(axis: .vertical, value: 0, discrete: nil, stop: true))
            events.append(.scroll(axis: .horizontal, value: 0, discrete: nil, stop: true))
        }
        return events
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
