import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

/// Draws decoded pictures into a `CAMetalLayer` in two passes:
///
/// 1. Conversion, once per picture: a compute kernel turns the decoded
///    YCbCr planes into an RGB texture at stream resolution, with upstream's
///    fixed-point BT.709 limited-range arithmetic, so the result equals
///    upstream's reference decoder output byte for byte:
///    - Single420: one biplanar 4:2:0 buffer, each chroma sample repeated
///      over its 2×2 block (`gliff-sw` `i420_to_bgra`);
///    - Dual420: the main and auxiliary buffers of one frame, recombined to
///      4:4:4 with upstream's AVC444 layout (`gliff-proto` `chroma.rs`
///      `recombine_yuv444`, `gliff-vk` `recombine.comp`), then converted
///      per pixel (`gliff-sw` `yuv444_to_bgra`).
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
    private let recombinePipeline: any MTLComputePipelineState
    private let presentPipeline: any MTLRenderPipelineState
    private let nearest: any MTLSamplerState
    private let linear: any MTLSamplerState
    private let textureCache: CVMetalTextureCache
    private let log = Logger(subsystem: "com.remi-b.gliff-mac", category: "video")

    /// The converted picture: kept to redraw on resize without converting again.
    private var converted: (sequence: UInt64, texture: any MTLTexture, geometry: FrameGeometry)?

    /// Nonblocking limit on committed presentation buffers and retained surfaces.
    let submissions = RenderSubmissionLimit(limit: 3)
    private var cacheVersion: UInt64 = 0

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// GPU cost of the conversion passes, from Metal's own timestamps.
    let metrics = RendererMetrics()

    init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
            let cache
        else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let kernel = library.makeFunction(name: "convert_biplanar420"),
                let recombine = library.makeFunction(name: "recombine_dual420"),
                let vertex = library.makeFunction(name: "fit_quad"),
                let fragment = library.makeFunction(name: "present_rgb")
            else { return nil }
            convertPipeline = try device.makeComputePipelineState(function: kernel)
            recombinePipeline = try device.makeComputePipelineState(function: recombine)
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
        guard submissions.acquire() else { return false }
        var committed = false
        defer { if !committed { submissions.release() } }
        guard let drawable = nextDrawable(layer), let commands = queue.makeCommandBuffer() else { return false }
        let picture = frame.flatMap { texture(for: $0, commands) }
        if frame != nil && picture == nil { return false }
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
        if let frame, let picture { cache(frame, picture: picture, commands: commands) }
        Self.releaseSubmission(submissions, after: commands)
        committed = true
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
        cacheVersion &+= 1
        converted = (frame.sequence, picture.texture, picture.geometry)
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    /// Releases the converted picture and flushes the texture cache.
    func reset() {
        cacheVersion &+= 1
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
        var width = min(frame.geometry.width, CVPixelBufferGetWidth(buffer))
        var height = min(frame.geometry.height, CVPixelBufferGetHeight(buffer))
        var planes = [(buffer, 0, MTLPixelFormat.r8Uint), (buffer, 1, MTLPixelFormat.rg8Uint)]
        if let aux = frame.aux {
            // The AVC444 layout needs even sizes, like upstream, which crops
            // a decoded picture to even dimensions before recombining.
            width = min(width, CVPixelBufferGetWidth(aux)) & ~1
            height = min(height, CVPixelBufferGetHeight(aux)) & ~1
            planes += [(aux, 0, .r8Uint), (aux, 1, .rg8Uint)]
        }
        let mapped = planes.compactMap { planeTexture($0.0, plane: $0.1, format: $0.2) }
        let textures = mapped.compactMap { CVMetalTextureGetTexture($0) }
        guard width > 0, height > 0, CVPixelBufferGetPlaneCount(buffer) == 2,
            frame.aux.map({ CVPixelBufferGetPlaneCount($0) == 2 }) ?? true,
            textures.count == planes.count,
            let output = outputTexture(width: width, height: height),
            let encoder = commands.makeComputeCommandEncoder()
        else {
            log.error("cannot map decoded frame \(frame.frameID) for display")
            return nil
        }
        var coefficients = frame.color.coefficients
        encoder.setComputePipelineState(frame.aux == nil ? convertPipeline : recombinePipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        encoder.setTexture(output, index: textures.count)
        encoder.setBytes(&coefficients, length: MemoryLayout<ColorConversion.Coefficients>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        encoder.endEncoding()
        // The CoreVideo textures (and so the IOSurfaces) must outlive the GPU work.
        var retained: [AnyObject] = mapped
        retained.append(buffer)
        if let aux = frame.aux { retained.append(aux) }
        Self.release(Retained(retained), after: commands, metrics: metrics, dual: frame.aux != nil)
        var geometry = frame.geometry
        geometry.width = width
        geometry.height = height
        return (output, geometry)
    }

    /// Publish a conversion to the cache only after successful GPU completion.
    /// A reset or a newer submission supersedes any late completion.
    private func cache(
        _ frame: DecodedFrame, picture: (texture: any MTLTexture, geometry: FrameGeometry),
        commands: any MTLCommandBuffer
    ) {
        cacheVersion &+= 1
        let version = cacheVersion
        Self.cacheOnSuccess(commands, renderer: self, version: version, sequence: frame.sequence,
                            texture: picture.texture, geometry: picture.geometry)
    }

    private nonisolated static func cacheOnSuccess(
        _ commands: any MTLCommandBuffer, renderer: VideoRenderer, version: UInt64, sequence: UInt64,
        texture: any MTLTexture, geometry: FrameGeometry
    ) {
        let picture = CachedTexture(texture: texture, geometry: geometry)
        commands.addCompletedHandler { buffer in
            guard buffer.status == .completed else { return }
            Task { @MainActor [weak renderer] in
                guard let renderer, renderer.cacheVersion == version else { return }
                renderer.converted = (sequence, picture.texture, picture.geometry)
            }
        }
    }

    private nonisolated static func releaseSubmission(
        _ limit: RenderSubmissionLimit, after commands: any MTLCommandBuffer
    ) {
        commands.addCompletedHandler { _ in limit.release() }
    }

    /// Metal calls completion handlers on its own queue. Formed outside the
    /// main actor, the handler is not main-actor isolated: older SDKs do not
    /// mark the block `@Sendable`, and Swift 6 would otherwise infer the
    /// isolation and trap when Metal runs it (seen on macOS 15 / Xcode 16.4).
    private nonisolated static func release(
        _ retained: Retained, after commands: any MTLCommandBuffer, metrics: RendererMetrics, dual: Bool
    ) {
        commands.addCompletedHandler { buffer in
            retained.release()
            if buffer.status == .completed, buffer.gpuEndTime > buffer.gpuStartTime {
                metrics.record(seconds: buffer.gpuEndTime - buffer.gpuStartTime, dual: dual)
            }
        }
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

        static inline float4 to_rgb(int luma, ushort2 c, constant Coefficients &k) {
            int y = luma - k.yOffset;
            int cb = int(c.x) - 128;
            int cr = int(c.y) - 128;
            const int rounding = 1 << 12;
            int r = (k.ky * y + k.krv * cr + rounding) >> 13;
            int g = (k.ky * y + k.kgu * cb + k.kgv * cr + rounding) >> 13;
            int b = (k.ky * y + k.kbu * cb + rounding) >> 13;
            return float4(channel(r), channel(g), channel(b), 1.0f);
        }

        // gliff-sw `convert::scalar::row_bgra`: 13-bit fixed point, rounded,
        // each chroma sample covering a 2x2 block.
        kernel void convert_biplanar420(texture2d<ushort, access::read> luma [[texture(0)]],
                                        texture2d<ushort, access::read> chroma [[texture(1)]],
                                        texture2d<float, access::write> rgb [[texture(2)]],
                                        constant Coefficients &k [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
            rgb.write(to_rgb(int(luma.read(gid).r), chroma.read(gid / 2).rg, k), gid);
        }

        // gliff-proto `chroma::recombine_yuv444` (the AVC444 layout, as in
        // gliff-vk `recombine.comp`), then `row_bgra` per pixel. With H the
        // (even) height:
        //   even row, even column: main.UV[y/2][x/2]
        //   even row, odd column:  aux.UV[y/2][x/2]
        //   odd row:               U = aux.Y[y/2][x], V = aux.Y[H/2 + y/2][x]
        kernel void recombine_dual420(texture2d<ushort, access::read> main_y [[texture(0)]],
                                      texture2d<ushort, access::read> main_uv [[texture(1)]],
                                      texture2d<ushort, access::read> aux_y [[texture(2)]],
                                      texture2d<ushort, access::read> aux_uv [[texture(3)]],
                                      texture2d<float, access::write> rgb [[texture(4)]],
                                      constant Coefficients &k [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
            uint width = rgb.get_width(), height = rgb.get_height();
            if (gid.x >= width || gid.y >= height) return;
            ushort2 c;
            if ((gid.y & 1) == 0) {
                c = (gid.x & 1) == 0 ? main_uv.read(gid / 2).rg : aux_uv.read(gid / 2).rg;
            } else {
                uint row = gid.y / 2;
                c = ushort2(aux_y.read(uint2(gid.x, row)).r, aux_y.read(uint2(gid.x, height / 2 + row)).r);
            }
            rgb.write(to_rgb(int(main_y.read(gid).r), c, k), gid);
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

/// GPU time of the conversion passes (Single420 conversion, Dual420
/// recombination), measured by Metal; for diagnostics and task 12.
final class RendererMetrics: Sendable {
    struct Snapshot: Equatable, Sendable {
        var conversions: UInt64 = 0
        var recombinations: UInt64 = 0
        /// GPU time of the command buffers that converted a picture (the
        /// presentation pass shares the buffer when drawing).
        var gpuMicrosTotal: UInt64 = 0
        var gpuMicrosMax: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    var snapshot: Snapshot { state.withLock { $0 } }

    func record(seconds: CFTimeInterval, dual: Bool) {
        let micros = UInt64(max(0, seconds * 1e6).rounded())
        state.withLock {
            if dual { $0.recombinations += 1 } else { $0.conversions += 1 }
            $0.gpuMicrosTotal += micros
            $0.gpuMicrosMax = max($0.gpuMicrosMax, micros)
        }
    }
}

/// Keeps CoreVideo objects alive until a command buffer completes.
private final class Retained: @unchecked Sendable {
    private var objects: [AnyObject]?
    private let lock = NSLock()

    init(_ objects: [AnyObject]) { self.objects = objects }

    func release() { lock.withLock { objects = nil } }
}

/// Counts GPU submissions without ever waiting on the presentation thread.
final class RenderSubmissionLimit: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    let limit: Int
    init(limit: Int) { precondition(limit > 0); self.limit = limit }
    func acquire() -> Bool {
        count.withLock { value in
            guard value < limit else { return false }
            value += 1
            return true
        }
    }
    func release() { count.withLock { value in precondition(value > 0); value -= 1 } }
    var inFlight: Int { count.withLock { $0 } }
}

private final class CachedTexture: @unchecked Sendable {
    let texture: any MTLTexture
    let geometry: FrameGeometry
    init(texture: any MTLTexture, geometry: FrameGeometry) {
        self.texture = texture
        self.geometry = geometry
    }
}
