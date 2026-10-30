import CoreGraphics
import CoreVideo
import GliffCore

/// The remote picture's geometry, from the configuration in force when its
/// frame was decoded. It travels with each decoded frame, so a resize never
/// pairs a picture with another configuration's sizes.
struct FrameGeometry: Equatable, Sendable {
    /// Coded size in stream pixels.
    var width: Int
    var height: Int
    /// Stream pixels per remote logical pixel ×1000 (input mapping, task 09).
    var scaleMilli: UInt32

    init(width: Int, height: Int, scaleMilli: UInt32 = 1000) {
        self.width = width
        self.height = height
        self.scaleMilli = scaleMilli
    }

    init(_ config: VideoConfig) {
        self.init(width: Int(config.width), height: Int(config.height), scaleMilli: config.scaleMilli)
    }

    /// Where the picture goes in a `drawable`-sized surface, in its pixels:
    /// aspect fit, centred, letterboxed, on whole pixels. A fit within half
    /// a percent of 1:1 snaps to exactly 1:1, so a matching window stays sharp.
    func fit(in drawable: CGSize) -> CGRect {
        guard width > 0, height > 0, drawable.width >= 1, drawable.height >= 1 else { return .zero }
        var scale = min(drawable.width / CGFloat(width), drawable.height / CGFloat(height))
        if abs(scale - 1) < 0.005 { scale = 1 }
        let size = CGSize(
            width: max(1, (CGFloat(width) * scale).rounded()),
            height: max(1, (CGFloat(height) * scale).rounded()))
        return CGRect(
            x: ((drawable.width - size.width) / 2).rounded(.down),
            y: ((drawable.height - size.height) / 2).rounded(.down),
            width: size.width, height: size.height)
    }
}

/// How decoded YCbCr samples become RGB: the buffer's matrix and range.
/// Upstream encodes BT.709 limited range (OpenH264 `VuiConfig::bt709`) and
/// converts back with 13-bit fixed point; these are the same integers, so
/// the GPU output matches upstream's reference decoder byte for byte.
struct ColorConversion: Equatable, Sendable {
    enum Matrix: Equatable, Sendable { case bt709, bt601 }

    var matrix: Matrix
    var fullRange: Bool

    static let reference = ColorConversion(matrix: .bt709, fullRange: false)

    /// 2^13 fixed point: R = (ky·(Y−y0) + krv·Cr' + ½) >> 13, and so on.
    struct Coefficients: Equatable {
        var yOffset: Int32
        var ky: Int32
        var krv: Int32
        var kgu: Int32
        var kgv: Int32
        var kbu: Int32
    }

    var coefficients: Coefficients {
        switch (matrix, fullRange) {
        // gliff-sw `convert.rs`: KY, KRV, KGU, KGV, KBU.
        case (.bt709, false): Coefficients(yOffset: 16, ky: 9539, krv: 14686, kgu: -1747, kgv: -4366, kbu: 17305)
        case (.bt709, true): Self.fixed(yOffset: 0, ky: 1, krv: 1.5748, kgu: -0.1873, kgv: -0.4681, kbu: 1.8556)
        case (.bt601, false): Self.fixed(yOffset: 16, ky: 1.1644, krv: 1.5960, kgu: -0.3918, kgv: -0.8130, kbu: 2.0172)
        case (.bt601, true): Self.fixed(yOffset: 0, ky: 1, krv: 1.4020, kgu: -0.3441, kgv: -0.7141, kbu: 1.7720)
        }
    }

    private static func fixed(
        yOffset: Int32, ky: Double, krv: Double, kgu: Double, kgv: Double, kbu: Double
    ) -> Coefficients {
        func q(_ v: Double) -> Int32 { Int32((v * 8192).rounded()) }
        return Coefficients(yOffset: yOffset, ky: q(ky), krv: q(krv), kgu: q(kgu), kgv: q(kgv), kbu: q(kbu))
    }

    /// Reads the decoded buffer's own metadata; untagged buffers follow the
    /// upstream reference (BT.709).
    init(_ buffer: CVPixelBuffer) {
        fullRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let tag = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        matrix = tag == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) ? .bt601 : .bt709
    }

    init(matrix: Matrix, fullRange: Bool) {
        self.matrix = matrix
        self.fullRange = fullRange
    }
}

/// One picture the decoder produced, ready to present. The pixel buffer is
/// IOSurface-backed and Metal compatible; it is immutable once delivered.
struct DecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let geometry: FrameGeometry
    let color: ColorConversion
    let generation: UInt32
    let frameID: UInt64
    let ptsMicros: UInt64
    /// Set by the display: increases with every picture posted to it.
    var sequence: UInt64 = 0
}
