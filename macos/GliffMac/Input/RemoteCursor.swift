import AppKit
import GliffCore

/// The remote pointer's image, shown as the surface's own cursor.
///
/// Like upstream's client, the remote shape replaces the local pointer over
/// the surface while input is captured: the Mac draws it at the real pointer
/// position with no network latency, and the remote position follows through
/// absolute motion events. When capture is released the surface draws a real
/// shape at CursorPos instead. A shape with no
/// visible pixels (Hyprland shares fully transparent or flat images, see
/// upstream's `hardware-quirks.md`) means "no image": a headless session
/// then hides the local pointer, because its pictures already contain the
/// compositor-drawn cursor; a mirrored session shows the arrow.
struct RemoteCursorImage: Equatable, Sendable {
    var id: UInt32
    var width: Int
    var height: Int
    /// The hotspot in image pixels, inside the image.
    var hotX: Int
    var hotY: Int
    /// Premultiplied ARGB words, little endian (BGRA bytes), row major.
    var pixels: Data

    /// `nil` for a malformed shape: empty, too large, a short payload or a
    /// hotspot outside the image.
    init?(_ shape: CursorShape) {
        guard let argb = shape.argb else { return nil }
        let width = Int(shape.width), height = Int(shape.height)
        guard (1...1024).contains(width), (1...1024).contains(height),
            argb.count >= width * height * 4,
            (0..<width).contains(Int(shape.hotX)), (0..<height).contains(Int(shape.hotY))
        else { return nil }
        id = shape.id
        self.width = width
        self.height = height
        hotX = Int(shape.hotX)
        hotY = Int(shape.hotY)
        pixels = Data(argb.prefix(width * height * 4))
    }

    /// Some pixel is not transparent and not all pixels are the same.
    var hasVisibleShape: Bool {
        pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var opaque = false
            var uniform = true
            for offset in stride(from: 0, to: raw.count, by: 4) {
                if raw[offset + 3] != 0 { opaque = true }
                if (0..<4).contains(where: { raw[offset + $0] != raw[$0] }) { uniform = false }
                if opaque && !uniform { return true }
            }
            return false
        }
    }
}

/// What the surface shows for the pointer while input is captured.
enum RemoteCursor: Equatable {
    /// The remote shape.
    case image(RemoteCursorImage)
    /// Nothing: the pictures carry the remote cursor.
    case hidden
    /// The ordinary arrow.
    case arrow

    init(image: RemoteCursorImage?, headless: Bool) {
        if let image, image.hasVisibleShape {
            self = .image(image)
        } else {
            self = headless ? .hidden : .arrow
        }
    }

    /// The cursor, its image scaled so one remote pixel covers
    /// `pointsPerPixel` points, as large as the remote shows it in the picture.
    @MainActor func makeCursor(pointsPerPixel: CGFloat) -> NSCursor {
        switch self {
        case .arrow: return .arrow
        case .hidden: return Self.hiddenCursor
        case .image(let image):
            guard let cursor = Self.cursor(image, pointsPerPixel: pointsPerPixel) else { return .arrow }
            return cursor
        }
    }

    static func cgImage(_ image: RemoteCursorImage) -> CGImage? {
        guard let provider = CGDataProvider(data: image.pixels as CFData),
            let cgImage = CGImage(
                width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return cgImage
    }

    @MainActor private static func cursor(_ image: RemoteCursorImage, pointsPerPixel: CGFloat) -> NSCursor? {
        guard let cgImage = cgImage(image) else { return nil }
        let scale = pointsPerPixel > 0 ? pointsPerPixel : 1
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let hotSpot = NSPoint(x: CGFloat(image.hotX) * scale, y: CGFloat(image.hotY) * scale)
        return NSCursor(image: NSImage(cgImage: cgImage, size: size), hotSpot: hotSpot)
    }

    /// A fully transparent cursor.
    @MainActor static let hiddenCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()
}
