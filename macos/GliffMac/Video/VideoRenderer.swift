import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

/// Draws decoded pictures into a `CAMetalLayer` in two passes:
///
/// 1. Conversion, once per picture: a compute kernel turns the biplanar
///    4:2:0 buffer into an RGB texture at stream resolution, with upstream's
///    fixed-point BT.709 limited-range arithmetic and each chroma sample
///    repeated over its 2×2 block, so the result equals upstream's reference
///    decoder output byte for byte. Task 08's Dual420 recombination
///    replaces this pass; presentation stays as is.
/// 2. Presentation, on every new picture and resize: the RGB texture is
///    fitted into the drawable (`FrameGeometry.fit`), letterboxed in black,
///    with nearest sampling at exactly 1:1 and linear sampling otherwise.
///
/// Shaders compile from source at start-up, so the build needs no Metal
/// toolchain. Main actor: the surface draws from AppKit layout and from the
/// display's wake-ups, which it hops to the main queue.
@MainActor
final class VideoRenderer {
    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let convertPipeline: any MTLComputePipelineState
    private let presentPipeline: any MTLRenderPipelineState
    private let nearest: any MTLSamplerState
    private let linear: any MTLSamplerState
    private let textureCache: CVMetalTextureCache
    private let log = Logger(subsystem: "com.remi-b.gliff-mac", category: "video")

    /// The converted picture: kept to redraw on resize without converting again.
    private var converted: (sequence: UInt64, texture: any MTLTexture, geometry: FrameGeometry)?

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
            let cache
        else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let kernel = library.makeFunction(name: "convert_biplanar420"),
                let vertex = library.makeFunction(name: "fit_quad"),
                let fragment = library.makeFunction(name: "present_rgb")
            else { return nil }
            convertPipeline = try device.makeComputePipelineState(function: kernel)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            presentPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Logger(subsystem: "com.remi-b.gliff-mac", category: "video")
                .error("cannot build the video shaders: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        func sampler(_ filter: MTLSamplerMinMagFilter) -> (any MTLSamplerState)? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let nearest = sampler(.nearest), let linear = sampler(.linear) else { return nil }
        self.device = device
        self.queue = queue
        self.nearest = nearest
        self.linear = linear
        textureCache = cache
    }

    /// Prepares `layer` for this renderer: sRGB, like the Linux client's
    /// BGRA surfaces, and opaque.
    func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = Self.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
    }

    /// Tests only: replaces `CAMetalLayer.nextDrawable()`.
    var nextDrawable: (CAMetalLayer) -> (any CAMetalDrawable)? = { $0.nextDrawable() }

    /// Draws `frame` (or black without one) into the layer's next drawable.
    /// Returns `false` when nothing was presented although the layer has a
    /// size (no drawable in time): the caller must draw again later.
    @discardableResult
    func draw(_ frame: DecodedFrame?, in layer: CAMetalLayer) -> Bool {
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1 else { return true }
        guard let commands = queue.makeCommandBuffer() else { return false }
        let picture = frame.flatMap { texture(for: $0, commands) }
        guard let drawable = nextDrawable(layer) else {
            // Still run the conversion: the cached texture must hold the picture.
            commands.commit()
            return false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if let picture {
            let rect = picture.geometry.fit(in: size)
            let exact = Int(rect.width) == picture.geometry.width && Int(rect.height) == picture.geometry.height
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setViewport(
                MTLViewport(
                    originX: rect.minX, originY: rect.minY, width: rect.width, height: rect.height,
                    znear: 0, zfar: 1))
            encoder.setFragmentTexture(picture.texture, index: 0)
            encoder.setFragmentSamplerState(exact ? nearest : linear, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        return true
    }

    /// The picture converted to RGBA bytes (stream size, rows packed), for
    /// tests and diagnostics. Waits for the GPU.
    func convertedPixels(_ frame: DecodedFrame) -> [UInt8]? {
        guard let commands = queue.makeCommandBuffer(), let picture = texture(for: frame, commands) else {
            return nil
        }
        let (width, height) = (picture.texture.width, picture.texture.height)
        guard let buffer = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
            let blit = commands.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: picture.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    /// Releases the converted picture and flushes the texture cache.
    func reset() {
        converted = nil
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// The RGB texture of `frame`, converting it in `commands` when it is new.
    private func texture(
        for frame: DecodedFrame, _ commands: any MTLCommandBuffer
    ) -> (texture: any MTLTexture, geometry: FrameGeometry)? {
        if let converted, converted.sequence == frame.sequence {
            return (converted.texture, converted.geometry)
        }
        let buffer = frame.pixelBuffer
        let width = min(frame.geometry.width, CVPixelBufferGetWidth(buffer))
        let height = min(frame.geometry.height, CVPixelBufferGetHeight(buffer))
        guard CVPixelBufferGetPlaneCount(buffer) == 2, width > 0, height > 0,
            let luma = planeTexture(buffer, plane: 0, format: .r8Uint),
            let chroma = planeTexture(buffer, plane: 1, format: .rg8Uint),
            let lumaTexture = CVMetalTextureGetTexture(luma),
            let chromaTexture = CVMetalTextureGetTexture(chroma),
            let output = outputTexture(width: width, height: height),
            let encoder = commands.makeComputeCommandEncoder()
        else {
            log.error("cannot map decoded frame \(frame.frameID) for display")
            return nil
        }
        var coefficients = frame.color.coefficients
        encoder.setComputePipelineState(convertPipeline)
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&coefficients, length: MemoryLayout<ColorConversion.Coefficients>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        encoder.endEncoding()
        // The CoreVideo textures (and so the IOSurface) must outlive the GPU work.
        Self.release(Retained([luma, chroma, buffer]), after: commands)
        var geometry = frame.geometry
        geometry.width = width
        geometry.height = height
        converted = (frame.sequence, output, geometry)
        return (output, geometry)
    }

    /// Metal calls completion handlers on its own queue. Formed outside the
    /// main actor, the handler is not main-actor isolated: older SDKs do not
    /// mark the block `@Sendable`, and Swift 6 would otherwise infer the
    /// isolation and trap when Metal runs it (seen on macOS 15 / Xcode 16.4).
    private nonisolated static func release(_ retained: Retained, after commands: any MTLCommandBuffer) {
        commands.addCompletedHandler { _ in retained.release() }
    }

    private func planeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane,
            &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    /// A new texture per picture: the previous one may still be on screen.
    private func outputTexture(width: Int, height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Coefficients { int yOffset; int ky; int krv; int kgu; int kgv; int kbu; };

        static inline float channel(int v) { return float(clamp(v, 0, 255)) / 255.0f; }

        // gliff-sw `convert::scalar::row_bgra`: 13-bit fixed point, rounded,
        // each chroma sample covering a 2x2 block.
        kernel void convert_biplanar420(texture2d<ushort, access::read> luma [[texture(0)]],
                                        texture2d<ushort, access::read> chroma [[texture(1)]],
                                        texture2d<float, access::write> rgb [[texture(2)]],
                                        constant Coefficients &k [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
            int y = int(luma.read(gid).r) - k.yOffset;
            ushort2 c = chroma.read(gid / 2).rg;
            int cb = int(c.x) - 128;
            int cr = int(c.y) - 128;
            const int rounding = 1 << 12;
            int r = (k.ky * y + k.krv * cr + rounding) >> 13;
            int g = (k.ky * y + k.kgu * cb + k.kgv * cr + rounding) >> 13;
            int b = (k.ky * y + k.kbu * cb + rounding) >> 13;
            rgb.write(float4(channel(r), channel(g), channel(b), 1.0f), gid);
        }

        struct Fitted { float4 position [[position]]; float2 uv; };

        // A quad covering the viewport, which the renderer sets to the fit.
        vertex Fitted fit_quad(uint id [[vertex_id]]) {
            float2 uv = float2(id & 1, id >> 1);
            Fitted out;
            out.position = float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1);
            out.uv = uv;
            return out;
        }

        fragment float4 present_rgb(Fitted in [[stage_in]], texture2d<float> rgb [[texture(0)]],
                                    sampler s [[sampler(0)]]) {
            return rgb.sample(s, in.uv);
        }
        """
}

/// Keeps CoreVideo objects alive until a command buffer completes.
private final class Retained: @unchecked Sendable {
    private var objects: [AnyObject]?
    private let lock = NSLock()

    init(_ objects: [AnyObject]) { self.objects = objects }

    func release() { lock.withLock { objects = nil } }
}
