import CoreVideo
import Foundation

/// CPU ports of upstream's reference chroma and colour code at the pinned
/// SHA, written independently of the Metal kernels they check:
///
/// - `gliff-sw` `convert.rs` scalar kernels: BGRA ↔ YCbCr, BT.709 limited
///   range, 13-bit fixed point (`row_y`, `row_uv`, `row_bgra`);
/// - `gliff-proto` `chroma.rs`: `split_yuv444`, `recombine_yuv444`, and
///   `gliff-sw`'s `decoded_to_nv12` crop to even sizes.
enum ChromaReference {
    /// Planar 4:4:4, tightly packed (`chroma::Yuv444`).
    struct Yuv444: Equatable {
        var width: Int
        var height: Int
        var y: [UInt8]
        var u: [UInt8]
        var v: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            y = [UInt8](repeating: 0, count: width * height)
            u = y
            v = y
        }
    }

    /// One NV12 frame, tightly packed (`chroma::Nv12`).
    struct Nv12: Equatable {
        var width: Int
        var height: Int
        var y: [UInt8]
        var uv: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            y = [UInt8](repeating: 0, count: width * height)
            uv = [UInt8](repeating: 0, count: width * height / 2)
        }
    }

    private static func clamp(_ v: Int32) -> UInt8 { UInt8(max(0, min(255, v))) }

    /// `convert::bgra_to_yuv444` (scalar `row_y` and `row_uv`, step 1).
    static func yuv444(bgra: [UInt8], width: Int, height: Int) -> Yuv444 {
        var out = Yuv444(width: width, height: height)
        let yBias: Int32 = (16 << 13) + 4096
        let cBias: Int32 = (128 << 13) + 4096
        for i in 0..<(width * height) {
            let b = Int32(bgra[i * 4])
            let g = Int32(bgra[i * 4 + 1])
            let r = Int32(bgra[i * 4 + 2])
            out.y[i] = clamp((1496 * r + 5032 * g + 508 * b + yBias) >> 13)
            out.u[i] = clamp((-824 * r - 2774 * g + 3598 * b + cBias) >> 13)
            out.v[i] = clamp((3598 * r - 3268 * g - 330 * b + cBias) >> 13)
        }
        return out
    }

    /// `chroma::split_yuv444`.
    static func split(_ src: Yuv444) -> (main: Nv12, aux: Nv12) {
        let (w, h) = (src.width, src.height)
        precondition(w % 2 == 0 && h % 2 == 0, "dimensions must be even")
        var main = Nv12(width: w, height: h)
        var aux = Nv12(width: w, height: h)
        main.y = src.y
        for by in 0..<(h / 2) {
            for bx in 0..<(w / 2) {
                let dst = by * w + bx * 2
                let even = 2 * by * w + 2 * bx
                main.uv[dst] = src.u[even]
                main.uv[dst + 1] = src.v[even]
                aux.uv[dst] = src.u[even + 1]
                aux.uv[dst + 1] = src.v[even + 1]
            }
        }
        let half = h / 2
        for y in 0..<half {
            let odd = (2 * y + 1) * w
            for x in 0..<w {
                aux.y[y * w + x] = src.u[odd + x]
                aux.y[(half + y) * w + x] = src.v[odd + x]
            }
        }
        return (main, aux)
    }

    /// `chroma::recombine_yuv444`.
    static func recombine(main: Nv12, aux: Nv12) -> Yuv444 {
        let (w, h) = (main.width, main.height)
        precondition(w % 2 == 0 && h % 2 == 0, "dimensions must be even")
        var out = Yuv444(width: w, height: h)
        out.y = main.y
        let half = h / 2
        for by in 0..<(h / 2) {
            for bx in 0..<(w / 2) {
                let m = by * w + bx * 2
                let row = 2 * by * w
                out.u[row + 2 * bx] = main.uv[m]
                out.v[row + 2 * bx] = main.uv[m + 1]
                out.u[row + 2 * bx + 1] = aux.uv[m]
                out.v[row + 2 * bx + 1] = aux.uv[m + 1]
            }
        }
        for y in 0..<half {
            let dst = (2 * y + 1) * w
            for x in 0..<w {
                out.u[dst + x] = aux.y[y * w + x]
                out.v[dst + x] = aux.y[(half + y) * w + x]
            }
        }
        return out
    }

    /// `convert::yuv444_to_bgra` (scalar `row_bgra`, no upsampling).
    static func bgra(_ src: Yuv444) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: src.width * src.height * 4)
        for i in 0..<(src.width * src.height) {
            let y = Int32(src.y[i]) - 16
            let cb = Int32(src.u[i]) - 128
            let cr = Int32(src.v[i]) - 128
            out[i * 4] = clamp((9539 * y + 17305 * cb + 4096) >> 13)
            out[i * 4 + 1] = clamp((9539 * y - 1747 * cb - 4366 * cr + 4096) >> 13)
            out[i * 4 + 2] = clamp((9539 * y + 14686 * cr + 4096) >> 13)
            out[i * 4 + 3] = 255
        }
        return out
    }

    /// `decoded_to_nv12`: a biplanar buffer (row strides may exceed the
    /// width) copied tightly packed, cropped to `width`×`height`.
    static func nv12(_ buffer: CVPixelBuffer, width: Int, height: Int) -> Nv12 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        var out = Nv12(width: width, height: height)
        for row in 0..<height {
            for col in 0..<width { out.y[row * width + col] = luma[row * lumaStride + col] }
        }
        for row in 0..<(height / 2) {
            for col in 0..<width { out.uv[row * width + col] = chroma[row * chromaStride + col] }
        }
        return out
    }

    /// Upstream's whole Dual420 client path after decoding (`gliff-sw`
    /// `recombine_to_bgra`): crop to even, recombine, convert. BGRA bytes.
    static func dualBGRA(main: CVPixelBuffer, aux: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        let (w, h) = (width & ~1, height & ~1)
        return bgra(recombine(main: nv12(main, width: w, height: h), aux: nv12(aux, width: w, height: h)))
    }

    /// An IOSurface-backed, Metal-compatible `420v` buffer holding `frame`,
    /// with rows padded to `alignment` bytes so strides exceed the width.
    static func pixelBuffer(_ frame: Nv12, alignment: Int = 256) -> CVPixelBuffer? {
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferBytesPerRowAlignmentKey: alignment,
        ] as CFDictionary
        var buffer: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                nil, frame.width, frame.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
                == kCVReturnSuccess, let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        // Fill the padding with a value the kernels must never read.
        memset(luma, 0xA5, lumaStride * frame.height)
        memset(chroma, 0x5A, chromaStride * frame.height / 2)
        for row in 0..<frame.height {
            for col in 0..<frame.width { luma[row * lumaStride + col] = frame.y[row * frame.width + col] }
        }
        for row in 0..<(frame.height / 2) {
            for col in 0..<frame.width { chroma[row * chromaStride + col] = frame.uv[row * frame.width + col] }
        }
        return buffer
    }

    /// PSNR over the colour channels of two BGRA images (`fixture-gen`
    /// `describe.rs`): 99 when identical.
    static func psnr(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Double {
        var sum = 0.0
        var n = 0
        for (i, (p, q)) in zip(a, b).enumerated() where i % 4 != 3 {
            let d = Double(p) - Double(q)
            sum += d * d
            n += 1
        }
        let mse = sum / Double(max(n, 1))
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// `describe.rs` `split_stripe`: PSNR over the 24 one-pixel red/cyan
    /// rows at half height, and over the rest of the picture.
    static func stripePSNR(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> (stripe: Double, rest: Double) {
        let row = width * 4
        let (start, end) = (height / 2 * row, height / 2 * row + 24 * row)
        let stripe = psnr(a[start..<end], b[start..<end])
        let rest = psnr(ArraySlice(Array(a[..<start]) + Array(a[end...])), ArraySlice(Array(b[..<start]) + Array(b[end...])))
        return (stripe, rest)
    }

    /// `fixture-gen` `synth::source_frame`: the synthetic fixtures' source
    /// picture, BGRA.
    static func syntheticSource(width w: Int, height h: Int, frameID: UInt64) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let blockX = Int(frameID) * 12 % (w - 48)
        for y in 0..<h {
            for x in 0..<w {
                var (r, g, b) = (UInt8(x * 255 / w), UInt8(y * 255 / h), UInt8(128))
                if (h / 2..<h / 2 + 24).contains(y) {
                    (r, g, b) = x % 2 == 0 ? (230, 20, 20) : (20, 230, 230)
                } else if (h / 4..<h / 4 + 20).contains(y), (16..<w / 2).contains(x) {
                    let on = (x / 2 + y / 2) % 2 == 0
                    (r, g, b) = on ? (250, 250, 250) : (10, 10, 10)
                }
                if (blockX..<blockX + 48).contains(x), (h - 48..<h - 16).contains(y) {
                    (r, g, b) = frameID % 2 == 0 ? (20, 40, 220) : (220, 180, 20)
                }
                let i = (y * w + x) * 4
                px[i] = b
                px[i + 1] = g
                px[i + 2] = r
                px[i + 3] = 255
            }
        }
        return px
    }
}
