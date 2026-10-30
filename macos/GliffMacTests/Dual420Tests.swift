import CoreMedia
import CoreText
import CoreVideo
import Foundation
import GliffCore
import Metal
import QuartzCore
import Testing
import VideoToolbox
import os
@testable import GliffMac

/// Dual420 recombination in Metal against independent CPU ports of
/// upstream's reference (`ChromaReference`), without H.264: synthetic
/// coloured text and chroma patterns, and every chroma sample position.
/// These are exact: the layout is a permutation and the conversion is the
/// same integer arithmetic on both sides.
@MainActor
@Suite(.serialized) struct ChromaRecombinationTests {
    /// Small coloured text on coloured backgrounds, one-pixel columns and
    /// rows of saturated colours: what 4:2:0 smears and 4:4:4 keeps.
    static func textPicture(width: Int, height: Int) -> [UInt8] {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let bands: [(CGColor, CGColor)] = [
            (CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), CGColor(srgbRed: 0.9, green: 0, blue: 0, alpha: 1)),
            (CGColor(srgbRed: 0, green: 0, blue: 0.8, alpha: 1), CGColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1)),
            (CGColor(srgbRed: 0, green: 0.6, blue: 0, alpha: 1), CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)),
            (CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)),
        ]
        let bandHeight = CGFloat(height) / CGFloat(bands.count + 1)
        for (index, (background, foreground)) in bands.enumerated() {
            let y = CGFloat(index) * bandHeight
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: y, width: CGFloat(width), height: bandHeight))
            let font = CTFontCreateWithName("Helvetica" as CFString, 8 + CGFloat(index), nil)
            let text = NSAttributedString(
                string: "Gliff 4:4:4 iIlL1| text, sharp colour #\(index)",
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
                ])
            context.textPosition = CGPoint(x: 3, y: y + bandHeight / 3)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        // The top band: one-pixel columns and rows of complementary colours.
        let top = CGFloat(bands.count) * bandHeight
        for x in 0..<width {
            context.setFillColor(
                x % 2 == 0
                    ? CGColor(srgbRed: 0.9, green: 0.08, blue: 0.08, alpha: 1)
                    : CGColor(srgbRed: 0.08, green: 0.9, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: CGFloat(x), y: top, width: 1, height: bandHeight / 2))
        }
        var row = top + bandHeight / 2
        while row < CGFloat(height) {
            context.setFillColor(
                Int(row) % 2 == 0
                    ? CGColor(srgbRed: 0.1, green: 0.1, blue: 0.95, alpha: 1)
                    : CGColor(srgbRed: 0.95, green: 0.85, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: CGFloat(width), height: 1))
            row += 1
        }
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: width * height * 4))
    }

    /// Deterministic noise: every chroma sample differs from its neighbours,
    /// so a sample read from the wrong position or plane shows.
    static func noise(width: Int, height: Int, seed: UInt32) -> ChromaReference.Yuv444 {
        var state = seed
        func next() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        var yuv = ChromaReference.Yuv444(width: width, height: height)
        for i in 0..<(width * height) {
            yuv.y[i] = next()
            yuv.u[i] = next()
            yuv.v[i] = next()
        }
        return yuv
    }

    /// The GPU's output for a main/aux pair (or main only), as BGRA.
    static func gpuBGRA(
        _ renderer: VideoRenderer, main: CVPixelBuffer, aux: CVPixelBuffer?, width: Int, height: Int,
        sequence: UInt64
    ) -> [UInt8]? {
        var frame = DecodedFrame(
            pixelBuffer: main, geometry: FrameGeometry(width: width, height: height), color: .reference,
            generation: 1, frameID: sequence, ptsMicros: 0, aux: aux)
        frame.sequence = sequence
        guard var pixels = renderer.convertedPixels(frame) else { return nil }
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(i, i + 2) }
        return pixels
    }

    static func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).enumerated().reduce(0) { worst, item in
            item.offset % 4 == 3 ? worst : max(worst, abs(Int(item.element.0) - Int(item.element.1)))
        }
    }

    /// Every sample position (even/odd row and column) with padded strides:
    /// GPU output equals the CPU reference byte for byte.
    @Test(arguments: [(64, 48, 16), (334, 96, 256), (2, 2, 64), (1920, 1080, 64)])
    func everyChromaSampleLandsWhereUpstreamPutsIt(_ size: (Int, Int, Int)) throws {
        let (width, height, alignment) = size
        let renderer = try #require(VideoRenderer())
        let source = Self.noise(width: width, height: height, seed: UInt32(width * 31 + height))
        let (main, aux) = ChromaReference.split(source)
        #expect(ChromaReference.recombine(main: main, aux: aux) == source, "the layout is lossless")
        let mainBuffer = try #require(ChromaReference.pixelBuffer(main, alignment: alignment))
        let auxBuffer = try #require(ChromaReference.pixelBuffer(aux, alignment: alignment))
        let gpu = try #require(
            Self.gpuBGRA(renderer, main: mainBuffer, aux: auxBuffer, width: width, height: height, sequence: 1))
        let expected = ChromaReference.bgra(source)
        #expect(gpu == expected)
        #expect(
            ChromaReference.dualBGRA(main: mainBuffer, aux: auxBuffer, width: width, height: height) == expected,
            "the strided CPU path agrees")
    }

    /// Coloured small text: the recombined picture equals the reference
    /// exactly, stays within the colour round trip of the source, and is
    /// far closer to it than Single420 (main picture alone).
    @Test func colouredSmallTextMatchesTheReference() throws {
        let (width, height) = (334, 120)
        let renderer = try #require(VideoRenderer())
        let source = Self.textPicture(width: width, height: height)
        let yuv = ChromaReference.yuv444(bgra: source, width: width, height: height)
        let (main, aux) = ChromaReference.split(yuv)
        let mainBuffer = try #require(ChromaReference.pixelBuffer(main))
        let auxBuffer = try #require(ChromaReference.pixelBuffer(aux))
        let dual = try #require(
            Self.gpuBGRA(renderer, main: mainBuffer, aux: auxBuffer, width: width, height: height, sequence: 1))
        #expect(dual == ChromaReference.bgra(yuv), "exact against the CPU reference")
        // BGRA → YCbCr → BGRA in 8-bit limited range: the quantisation of
        // the forward and inverse fixed-point matrices alone.
        let roundTrip = Self.maxDifference(dual, source)
        #expect(roundTrip <= ChromaTolerance.uncompressedRoundTrip, "round trip off by \(roundTrip)")
        let single = try #require(
            Self.gpuBGRA(renderer, main: mainBuffer, aux: nil, width: width, height: height, sequence: 2))
        let dualPSNR = ChromaReference.psnr(dual[...], source[...])
        let singlePSNR = ChromaReference.psnr(single[...], source[...])
        #expect(dualPSNR > 45 && dualPSNR - singlePSNR > 10, "Dual420 \(dualPSNR) dB, Single420 \(singlePSNR) dB")
    }

    /// GPU cost of the conversion and recombination passes at 1080p and 4K,
    /// recorded for task 12 (printed, not asserted: it depends on the Mac).
    @Test func recordsConversionCosts() throws {
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            let renderer = try #require(VideoRenderer())
            let source = Self.noise(width: width, height: height, seed: 7)
            let (main, aux) = ChromaReference.split(source)
            let mainBuffer = try #require(ChromaReference.pixelBuffer(main))
            let auxBuffer = try #require(ChromaReference.pixelBuffer(aux))
            let runs = 30
            for run in 0..<runs {
                _ = Self.gpuBGRA(
                    renderer, main: mainBuffer, aux: auxBuffer, width: width, height: height,
                    sequence: UInt64(2 * run + 1))
                _ = Self.gpuBGRA(
                    renderer, main: mainBuffer, aux: nil, width: width, height: height, sequence: UInt64(2 * run + 2))
            }
            // Completion handlers run after `waitUntilCompleted` returns.
            let deadline = Date.now.addingTimeInterval(2)
            while renderer.metrics.snapshot.recombinations + renderer.metrics.snapshot.conversions < UInt64(2 * runs),
                Date.now < deadline
            {
                usleep(10_000)
            }
            let metrics = renderer.metrics.snapshot
            #expect(metrics.recombinations == UInt64(runs) && metrics.conversions == UInt64(runs))
            let surfaces = [mainBuffer, auxBuffer].map {
                IOSurfaceGetAllocSize(CVPixelBufferGetIOSurface($0)!.takeUnretainedValue())
            }
            print(
                "chroma-metrics \(width)x\(height): \(runs) recombinations + \(runs) conversions, GPU mean "
                    + "\(metrics.gpuMicrosTotal / UInt64(2 * runs)) us max \(metrics.gpuMicrosMax) us (incl. readback); "
                    + "pair surfaces \(surfaces[0] + surfaces[1]) bytes, RGB texture \(width * height * 4) bytes")
        }
    }
}

/// Documented tolerances. Everything else in these suites is exact.
enum ChromaTolerance {
    /// Max per-channel error of BGRA → YCbCr 4:4:4 → BGRA in 8-bit BT.709
    /// limited range (upstream's fixed-point matrices), without H.264.
    static let uncompressedRoundTrip = 3
    /// The synthetic fixtures' lossy H.264 PSNR against their source: the
    /// manifest's values are rounded to 0.01 dB.
    static let manifestPSNR = 0.005
    /// Independent floors for the same fixtures, Dual420: the one-pixel
    /// red/cyan columns and the rest of the picture.
    static let dualStripeFloor = 39.0
    static let restFloor = 43.0
    /// Single420 cannot carry one-pixel colour: its stripe stays below this.
    static let singleStripeCeiling = 10.0
}

/// VideoToolbox Dual420 pair decoding on the committed fixtures, through
/// the real bridge, compared with upstream's reference decoder.
@MainActor
@Suite(.serialized) struct Dual420DecoderTests {
    /// Every pair decodes; the CPU port and the GPU recombination of each
    /// both equal upstream's `decoded_bgra_sha256` (OpenH264 decode,
    /// `recombine_yuv444`, fixed-point conversion) byte for byte.
    @Test(arguments: ["synthetic-dual420", "live-cpu-dual420", "live-gpu-dual420"])
    func decodesPairsExactlyLikeUpstream(_ name: String) async throws {
        let items = try await VideoFixtures.items(name)
        let hashes = try VideoFixtures.referenceHashes(name)
        let renderer = try #require(VideoRenderer())
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        var checked = 0
        for item in items {
            decoder.handle(item)
            guard let frame = item.frame else { continue }
            decoder.waitUntilIdle()
            let picture = try #require(decoder.display.latest)
            #expect(picture.frameID == frame.frameId && picture.generation == frame.generation)
            let aux = try #require(picture.aux, "frame \(frame.frameId) has its auxiliary picture")
            let (width, height) = (picture.geometry.width, picture.geometry.height)
            #expect(CVPixelBufferGetWidth(aux) == width && CVPixelBufferGetHeight(aux) == height)
            #expect(picture.color == .reference)
            let cpu = ChromaReference.dualBGRA(main: picture.pixelBuffer, aux: aux, width: width, height: height)
            #expect(sha256(cpu) == hashes[frame.frameId], "CPU recombination of frame \(frame.frameId)")
            var gpu = try #require(renderer.convertedPixels(picture))
            for i in stride(from: 0, to: gpu.count, by: 4) { gpu.swapAt(i, i + 2) }
            #expect(sha256(gpu) == hashes[frame.frameId], "GPU recombination of frame \(frame.frameId)")
            checked += 1
        }
        decoder.invalidateAndWait()
        let delivered = items.compactMap(\.frame).count
        #expect(checked == delivered && delivered >= hashes.count * 3 / 4, "\(delivered) of \(hashes.count)")
        #expect(log.all.count == delivered && log.all.allSatisfy { $0.outcome == .decoded })
        let diagnostics = decoder.display.diagnostics
        #expect(diagnostics.pairsDecoded == UInt64(delivered))
        #expect(diagnostics.failed == 0 && diagnostics.discarded == 0 && diagnostics.expired == 0)
        // Two sessions (main and aux) per generation.
        let generations = Set(items.compactMap(\.frame).map(\.generation)).count
        #expect(diagnostics.decoderSessions == UInt64(2 * generations))
        #expect(diagnostics.maxPending >= 1 && diagnostics.pictureBytes > 0 && diagnostics.fullChroma == true)
    }

    /// Lossy H.264 against independent expected data: the generator's own
    /// source picture (ported), not upstream's decoder output.
    @Test(arguments: ["synthetic-dual420", "synthetic-single420"])
    func syntheticFramesReachTheirSourceQuality(_ name: String) async throws {
        let items = try await VideoFixtures.items(name)
        let expected = try VideoFixtures.referencePSNR(name)
        let renderer = try #require(VideoRenderer())
        let decoder = H264Decoder(display: VideoDisplay(), report: ReportLog().reporter)
        let dual = name.hasSuffix("dual420")
        for item in items {
            decoder.handle(item)
            guard let frame = item.frame else { continue }
            decoder.waitUntilIdle()
            let picture = try #require(decoder.display.latest)
            let (width, height) = (picture.geometry.width, picture.geometry.height)
            var gpu = try #require(renderer.convertedPixels(picture))
            for i in stride(from: 0, to: gpu.count, by: 4) { gpu.swapAt(i, i + 2) }
            let source = ChromaReference.syntheticSource(width: width, height: height, frameID: frame.frameId)
            let (stripe, rest) = ChromaReference.stripePSNR(source, gpu, width: width, height: height)
            let reference = try #require(expected[frame.frameId])
            #expect(abs(stripe - reference.stripe) <= ChromaTolerance.manifestPSNR, "frame \(frame.frameId) stripe \(stripe)")
            #expect(abs(rest - reference.rest) <= ChromaTolerance.manifestPSNR, "frame \(frame.frameId) rest \(rest)")
            #expect(rest >= ChromaTolerance.restFloor)
            if dual {
                #expect(stripe >= ChromaTolerance.dualStripeFloor, "frame \(frame.frameId): \(stripe) dB")
            } else {
                #expect(stripe < ChromaTolerance.singleStripeCeiling)
            }
        }
        decoder.invalidateAndWait()
    }

    /// Single420 → Dual420 → Single420 generations, as the server's
    /// bandwidth ladder drops and restores the auxiliary stream: each
    /// picture carries exactly its generation's chroma, and a late frame of
    /// a replaced generation is discarded, never shown.
    @Test func chromaTransitionsNeverMixGenerations() async throws {
        let single = try await VideoFixtures.items("synthetic-single420")
        let dual = try await VideoFixtures.items("synthetic-dual420")
        func segment(_ items: [VideoItem], generation: UInt32, idOffset: UInt64) -> [VideoItem] {
            items.prefix { $0.config?.generation != 2 }.map { item -> VideoItem in
                switch item {
                case .config(var config):
                    config.generation = generation
                    return .config(config)
                case .frame(var frame):
                    frame.generation = generation
                    frame.frameId += idOffset
                    return .frame(frame)
                }
            }
        }
        let segments = [
            segment(single, generation: 1, idOffset: 0), segment(dual, generation: 2, idOffset: 100),
            segment(single, generation: 3, idOffset: 200),
        ]
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        for (index, segment) in segments.enumerated() {
            if index == 2 {
                // Configuration 3 arrives, then a late Dual420 frame.
                decoder.handle(segment[0])
                var late = try #require(segments[1].compactMap(\.frame).last)
                late.frameId = 199
                decoder.handle(.frame(late))
                decoder.waitUntilIdle()
                #expect(log.outcome(of: 199) == [.discarded])
                #expect(decoder.display.latest?.generation == 2, "the last picture stays until generation 3")
            }
            for item in segment.dropFirst(index == 2 ? 1 : 0) {
                decoder.handle(item)
                guard let frame = item.frame else { continue }
                decoder.waitUntilIdle()
                let picture = try #require(decoder.display.latest)
                #expect(picture.frameID == frame.frameId && picture.generation == frame.generation)
                #expect(picture.isFullChroma == (frame.generation == 2), "frame \(frame.frameId)")
            }
        }
        decoder.invalidateAndWait()
        let frames = segments.flatMap { $0.compactMap(\.frame) }
        #expect(frames.allSatisfy { log.outcome(of: $0.frameId) == [.decoded] })
        let diagnostics = decoder.display.diagnostics
        #expect(diagnostics.decoderSessions == 4, "main; main + aux; main")
        #expect(diagnostics.pairsDecoded == UInt64(segments[1].compactMap(\.frame).count))
        #expect(diagnostics.failed == 0 && diagnostics.discarded == 1)
    }

    /// An auxiliary access unit that cannot be decoded fails the whole
    /// frame at once; the picture freezes until the next keyframe pair.
    @Test func aBrokenAuxiliaryStreamFailsThePairAndRecovers() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let frames = items.compactMap(\.frame)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        decoder.handle(try #require(items.first))
        decoder.handle(.frame(frames[0]))
        decoder.handle(.frame(frames[1]))
        decoder.waitUntilIdle()
        #expect(decoder.display.latest?.frameID == 1)
        var broken = frames[2]
        broken.aux = Data([0, 0, 0, 1, 0x67, 0x42])
        decoder.handle(.frame(broken))
        decoder.handle(.frame(frames[3]))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: 2) == [.failed])
        #expect(log.outcome(of: 3) == [.discarded])
        #expect(decoder.display.latest?.frameID == 1 && decoder.display.diagnostics.recovering)
        let recovery = try #require(frames.first { $0.keyframe && $0.frameId > 3 && $0.generation == 1 })
        decoder.handle(.frame(recovery))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: recovery.frameId) == [.decoded])
        #expect(decoder.display.latest?.frameID == recovery.frameId && decoder.display.latest?.isFullChroma == true)
        #expect(!decoder.display.diagnostics.recovering)
        #expect(decoder.display.diagnostics.decoderSessions == 4, "both sessions recreated at the keyframe")
        decoder.invalidateAndWait()
    }

    /// Corrupt auxiliary slices reach VideoToolbox: whatever it makes of
    /// them, each frame is reported once, and a failure is a pair failure.
    @Test func corruptAuxiliarySamplesAreReportedOnce() async throws {
        let items = try await VideoFixtures.items("live-cpu-dual420")
        let frames = items.compactMap(\.frame)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        decoder.handle(try #require(items.first))
        var corrupt = frames[0]
        let aux = try #require(corrupt.aux)
        corrupt.aux = Data(aux.prefix(64)) + Data(repeating: 0x5a, count: 4096)
        var garbage = frames[1]
        garbage.aux = Data([0, 0, 0, 1, 0x41] + (0..<2048).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: i &* 37) })
        decoder.handle(.frame(corrupt))
        decoder.handle(.frame(garbage))
        decoder.waitUntilIdle()
        decoder.invalidateAndWait()
        for frame in [corrupt, garbage] {
            #expect(log.outcome(of: frame.frameId).count == 1, "frame \(frame.frameId) reported once")
        }
        let diagnostics = decoder.display.diagnostics
        #expect(diagnostics.halfFailures <= diagnostics.failed)
    }

    /// A half that never comes back: the frame fails at its deadline,
    /// exactly once, nothing half-coloured is shown, and the next keyframe
    /// pair recovers.
    @Test func aMissingPartnerTimesOutOnce() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let frames = items.compactMap(\.frame)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), completionTimeout: .milliseconds(150), report: log.reporter)
        decoder.handle(try #require(items.first))
        decoder.handle(.frame(frames[0]))
        decoder.waitUntilIdle()
        decoder.ignoreAuxOutput(true)
        decoder.handle(.frame(frames[1]))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: 1).isEmpty, "the main picture alone does not complete the frame")
        #expect(decoder.pendingCount == 1)
        try await waitUntil { !log.outcome(of: 1).isEmpty }
        #expect(log.outcome(of: 1) == [.failed])
        #expect(decoder.display.latest?.frameID == 0)
        #expect(decoder.display.diagnostics.expired == 1 && decoder.pendingCount == 0)
        decoder.ignoreAuxOutput(false)
        let recovery = try #require(frames.first { $0.keyframe && $0.frameId > 1 && $0.generation == 1 })
        for frame in frames[2...] where frame.frameId <= recovery.frameId { decoder.handle(.frame(frame)) }
        decoder.waitUntilIdle()
        #expect(log.outcome(of: recovery.frameId) == [.decoded])
        #expect(frames[2..<Int(recovery.frameId)].allSatisfy { log.outcome(of: $0.frameId) == [.discarded] })
        #expect(decoder.display.latest?.frameID == recovery.frameId)
        // The deadline of a frame that already settled does nothing.
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.all.count == Int(recovery.frameId) + 1)
        decoder.invalidateAndWait()
    }

    @Test func oldGenerationExpiryDoesNotInvalidateNewReferences() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let frames = items.compactMap(\.frame)
        var config = try #require(items.first?.config)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), completionTimeout: .milliseconds(300), report: log.reporter)
        decoder.ignoreAuxOutput(true)
        decoder.handle(.config(config))
        decoder.handle(.frame(frames[0]))
        decoder.waitUntilIdle()
        decoder.ignoreAuxOutput(false)
        config.generation = 2
        config.rebuild = true
        decoder.handle(.config(config))
        var key = frames[0]
        key.generation = 2
        key.frameId = 100
        decoder.handle(.frame(key))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: 100) == [.decoded])
        try await waitUntil { !log.outcome(of: 0).isEmpty }
        #expect(log.outcome(of: 0) == [.failed])
        var predicted = frames[1]
        predicted.generation = 2
        predicted.frameId = 101
        decoder.handle(.frame(predicted))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: 101) == [.decoded])
        #expect(decoder.display.latest?.frameID == 101)
        decoder.invalidateAndWait()
    }

    @Test func olderExpiryDoesNotInvalidateANewerIDRInTheSameGeneration() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let frames = items.compactMap(\.frame)
        let key = try #require(frames.first { $0.keyframe && $0.frameId > 1 && $0.generation == 1 })
        let predicted = try #require(frames.first { $0.frameId == key.frameId + 1 })
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), completionTimeout: .milliseconds(300), report: log.reporter)
        decoder.handle(try #require(items.first))
        decoder.handle(.frame(frames[0]))
        decoder.waitUntilIdle()
        decoder.ignoreAuxOutput(true)
        decoder.handle(.frame(frames[1]))
        decoder.waitUntilIdle()
        decoder.ignoreAuxOutput(false)
        decoder.handle(.frame(key))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: key.frameId) == [.decoded])
        try await waitUntil { !log.outcome(of: 1).isEmpty }
        #expect(log.outcome(of: 1) == [.failed])
        #expect(!decoder.display.diagnostics.recovering)
        decoder.handle(.frame(predicted))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: predicted.frameId) == [.decoded])
        #expect(decoder.display.latest?.frameID == predicted.frameId)
        decoder.invalidateAndWait()
    }

    @Test func failureBeforePublicationSuppressesStalePicture() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
        let once = OSAllocatedUnfairLock(initialState: false)
        decoder.beforePublication = { [weak decoder] in
            let first = once.withLock { state in
                if state { return false }
                state = true
                return true
            }
            if first { decoder?.failed(999, status: -1) }
        }
        decoder.handle(try #require(items.first))
        decoder.handle(.frame(try #require(items.compactMap(\.frame).first)))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: 0) == [.decoded])
        #expect(decoder.display.latest == nil)
        decoder.invalidateAndWait()
    }

    @Test func overflowDiscardsIncomingPredictedFrameBeforeSubmission() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let frames = items.compactMap(\.frame)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), completionTimeout: .seconds(30), pendingLimit: 1, report: log.reporter)
        decoder.handle(try #require(items.first))
        decoder.handle(.frame(frames[0]))
        decoder.waitUntilIdle()
        decoder.ignoreAuxOutput(true)
        decoder.handle(.frame(frames[1]))
        decoder.waitUntilIdle()
        decoder.handle(.frame(frames[2]))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: 1) == [.failed])
        #expect(log.outcome(of: 2) == [.discarded])
        #expect(decoder.pendingCount == 0 && decoder.display.latest?.frameID == 0)
        decoder.ignoreAuxOutput(false)
        let key = try #require(frames.first { $0.keyframe && $0.frameId > 2 && $0.generation == 1 })
        decoder.handle(.frame(key))
        decoder.waitUntilIdle()
        #expect(log.outcome(of: key.frameId) == [.decoded])
        #expect(decoder.display.latest?.frameID == key.frameId)
        decoder.invalidateAndWait()
    }

    /// Closing with a half still missing: the frame is reported once, as
    /// not decoded.
    @Test func closingWithAMissingPartnerReportsItOnce() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let frames = items.compactMap(\.frame)
        let log = ReportLog()
        let decoder = H264Decoder(display: VideoDisplay(), completionTimeout: .seconds(30), report: log.reporter)
        decoder.ignoreAuxOutput(true)
        decoder.handle(try #require(items.first))
        decoder.handle(.frame(frames[0]))
        decoder.invalidateAndWait()
        #expect(log.outcome(of: 0) == [.discarded])
        #expect(decoder.pendingCount == 0 && decoder.display.latest == nil)
    }

    /// Pairs that do not match their configuration fail before VideoToolbox:
    /// no auxiliary stream for Dual420, one for Single420, or a keyframe
    /// whose auxiliary half is not an IDR (a keyframe is requested again).
    @Test func mismatchedPairsFail() async throws {
        let dual = try await VideoFixtures.items("synthetic-dual420")
        let single = try await VideoFixtures.items("synthetic-single420")
        let dualFrames = dual.compactMap(\.frame)
        for (items, frame) in [
            (dual, { () -> EncodedFrame in
                var f = dualFrames[0]
                f.aux = nil
                return f
            }()),
            (single, { () -> EncodedFrame in
                var f = single.compactMap(\.frame)[0]
                f.aux = dualFrames[0].aux
                return f
            }()),
            (dual, { () -> EncodedFrame in
                var f = dualFrames[0]
                f.aux = dualFrames[1].aux
                return f
            }()),
        ] {
            let log = ReportLog()
            let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
            decoder.handle(try #require(items.first))
            decoder.handle(.frame(frame))
            decoder.waitUntilIdle()
            #expect(log.outcome(of: frame.frameId) == [.failed])
            #expect(decoder.display.latest == nil && decoder.display.diagnostics.decoderSessions == 0)
            decoder.invalidateAndWait()
        }
    }

    /// Disconnecting with pairs inside VideoToolbox: each frame is reported
    /// once, later ones are discarded, and the pictures are released.
    @Test func invalidatingWithPairsInFlightReportsEveryFrameOnce() async throws {
        let items = try await VideoFixtures.items("live-cpu-dual420")
        let frames = items.compactMap(\.frame)
        for cut in [1, 5, 15] {
            let log = ReportLog()
            let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
            let before = items.prefix(cut + 1)
            let handed = before.compactMap(\.frame).count
            before.forEach(decoder.handle)
            decoder.invalidate()
            items.dropFirst(cut + 1).forEach(decoder.handle)
            decoder.invalidateAndWait()
            #expect(log.all.count == frames.count, "cut \(cut)")
            #expect(Set(log.all.map(\.id)).count == frames.count)
            #expect(log.all.dropFirst(handed).allSatisfy { $0.outcome == .discarded })
            #expect(decoder.display.latest == nil && decoder.pendingCount == 0)
        }
    }

    /// The renderer presents recombined pictures at any size, and redraws
    /// the cached one without recombining again.
    @Test func theRendererDrawsDualPicturesAtAnySize() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let decoder = H264Decoder(display: VideoDisplay(), report: ReportLog().reporter)
        items.prefix(3).forEach(decoder.handle)
        decoder.waitUntilIdle()
        let renderer = try #require(VideoRenderer())
        let layer = CAMetalLayer()
        renderer.configure(layer)
        for size in [CGSize(width: 640, height: 384), CGSize(width: 333, height: 777), CGSize(width: 1, height: 1)] {
            layer.drawableSize = size
            renderer.draw(decoder.display.take(), in: layer)
            renderer.draw(decoder.display.take(), in: layer)
        }
        decoder.invalidateAndWait()
        let deadline = Date.now.addingTimeInterval(2)
        while renderer.metrics.snapshot.recombinations == 0, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(renderer.metrics.snapshot.recombinations >= 1, "at least one recombination completed")
    }

    @Test func rendererRetriesAfterNoDrawableAndSubmissionSaturation() async throws {
        let items = try await VideoFixtures.items("synthetic-dual420")
        let decoder = H264Decoder(display: VideoDisplay(), report: ReportLog().reporter)
        items.prefix(2).forEach(decoder.handle)
        decoder.waitUntilIdle()
        let frame = try #require(decoder.display.latest)
        let renderer = try #require(VideoRenderer())
        let layer = CAMetalLayer()
        renderer.configure(layer)
        layer.drawableSize = CGSize(width: 640, height: 384)
        renderer.nextDrawable = { _ in nil }
        #expect(!renderer.draw(frame, in: layer))
        #expect(renderer.submissions.inFlight == 0)
        for _ in 0..<renderer.submissions.limit { #expect(renderer.submissions.acquire()) }
        var attempts = 0
        renderer.nextDrawable = { layer in attempts += 1; return layer.nextDrawable() }
        #expect(!renderer.draw(frame, in: layer))
        #expect(attempts == 0)
        for _ in 0..<renderer.submissions.limit { renderer.submissions.release() }
        #expect(renderer.draw(frame, in: layer))
        try await waitUntil { renderer.submissions.inFlight == 0 }
        let bytes = try #require(renderer.convertedPixels(frame))
        var bgra = bytes
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        #expect(bgra == ChromaReference.dualBGRA(main: frame.pixelBuffer, aux: try #require(frame.aux),
                                                  width: frame.geometry.width, height: frame.geometry.height))
        renderer.reset()
        #expect(renderer.convertedPixels(frame) == bytes)
        decoder.invalidateAndWait()
    }

    /// Coordinator hook: replays recorded live sessions (for example
    /// `scripts/live-host-check.sh … --chroma dual420` output) natively.
    /// Run with `TEST_RUNNER_GLIFF_LIVE_STREAMS=/path/a.gliffstream:/path/b.gliffstream
    /// scripts/test-app.sh -only-testing:GliffMacTests/Dual420DecoderTests`.
    /// Every frame must decode; GPU output must equal the CPU reference, and
    /// a `<name>.json` manifest next to the stream (fixture-gen `describe`)
    /// must match too.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLIFF_LIVE_STREAMS"] != nil))
    func recordedLiveStreamsDecodeNatively() async throws {
        let paths = ProcessInfo.processInfo.environment["GLIFF_LIVE_STREAMS"]!.split(separator: ":").map(String.init)
        let renderer = try #require(VideoRenderer())
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let items = try await VideoFixtures.items(stream: try Data(contentsOf: url))
            let manifest = url.deletingPathExtension().appendingPathExtension("json")
            let hashes = FileManager.default.fileExists(atPath: manifest.path)
                ? try VideoFixtures.referenceHashes(manifest: manifest) : [:]
            let log = ReportLog()
            let decoder = H264Decoder(display: VideoDisplay(), report: log.reporter)
            var dualFrames = 0
            for item in items {
                decoder.handle(item)
                guard let frame = item.frame else { continue }
                decoder.waitUntilIdle()
                let picture = try #require(decoder.display.latest)
                let (width, height) = (picture.geometry.width, picture.geometry.height)
                let cpu = picture.aux.map {
                    ChromaReference.dualBGRA(main: picture.pixelBuffer, aux: $0, width: width, height: height)
                } ?? referenceBGRA(picture.pixelBuffer, width: width, height: height)
                var gpu = try #require(renderer.convertedPixels(picture))
                for i in stride(from: 0, to: gpu.count, by: 4) { gpu.swapAt(i, i + 2) }
                #expect(gpu == cpu, "\(url.lastPathComponent) frame \(frame.frameId)")
                if let hash = hashes[frame.frameId] { #expect(sha256(gpu) == hash) }
                if picture.isFullChroma { dualFrames += 1 }
            }
            decoder.invalidateAndWait()
            let diagnostics = decoder.display.diagnostics
            #expect(log.all.allSatisfy { $0.outcome == .decoded }, "\(url.lastPathComponent)")
            print(
                "live-replay \(url.lastPathComponent): \(log.all.count) frames, \(dualFrames) full chroma, "
                    + "\(hashes.count) manifest hashes, decoders \(diagnostics.decoderSessions), "
                    + "hardware \(String(describing: diagnostics.hardwareAccelerated)), "
                    + "completion max \(diagnostics.completionMicrosMax) us, picture bytes \(diagnostics.pictureBytes)")
        }
    }
}

/// The colour matrix comes from the stream's own VUI, BT.709 without one,
/// never from VideoToolbox's guess on the buffer. Regression: upstream's
/// VA-API encoder writes no VUI, VideoToolbox tagged its 640×480 pictures
/// BT.601, and the conversion no longer matched upstream.
@Suite struct ColorSignallingTests {
    @Test func untaggedStreamsFollowUpstreamBT709() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let pixels = try #require(buffer)
        CVBufferSetAttachment(
            pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        #expect(ColorConversion(pixels, format: nil) == .reference)

        func format(_ matrix: CFString?) throws -> CMFormatDescription {
            var extensions: [CFString: Any] = [:]
            if let matrix { extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix }
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreate(
                allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16,
                extensions: extensions as CFDictionary, formatDescriptionOut: &description)
            return try #require(description)
        }
        #expect(ColorConversion(pixels, format: try format(nil)) == .reference)
        #expect(ColorConversion(pixels, format: try format(kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)) == .reference)
        #expect(ColorConversion(pixels, format: try format(kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4)).matrix == .bt601)
    }
}

/// `FrameJob` alone: halves pair by frame, never by arrival order, and a
/// job settles exactly once whatever races it.
@Suite struct FrameJobTests {
    static func buffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        return buffer!
    }

    static func job(_ id: UInt64, dual: Bool = true) -> FrameJob {
        FrameJob(
            frameID: id, generation: 1, ptsMicros: 0, keyframe: false, geometry: FrameGeometry(width: 4, height: 4),
            epoch: 0, dual: dual)
    }

    @Test func halvesPairByFrameWhateverTheirOrder() {
        let (a, b) = (Self.job(1), Self.job(2))
        let (aMain, aAux, bMain, bAux) = (Self.buffer(), Self.buffer(), Self.buffer(), Self.buffer())
        #expect(b.record(.aux, .image(bAux)) == nil)
        #expect(a.record(.main, .image(aMain)) == nil)
        guard case .decoded(let main?, let aux?) = b.record(.main, .image(bMain)) else {
            Issue.record("frame 2 should complete")
            return
        }
        #expect(main === bMain && aux === bAux)
        guard case .decoded(let main2?, let aux2?) = a.record(.aux, .image(aAux)) else {
            Issue.record("frame 1 should complete")
            return
        }
        #expect(main2 === aMain && aux2 === aAux)
    }

    @Test func aFailedHalfSettlesAtOnceAndTheLatePartnerIsIgnored() {
        let job = Self.job(1)
        guard case .failed(let status, .aux)? = job.record(.aux, .failed(-12909)) else {
            Issue.record("expected a failure")
            return
        }
        #expect(status == -12909)
        #expect(job.record(.main, .image(Self.buffer())) == nil)
        #expect(job.expire() == nil && job.isSettled)
    }

    @Test func aMissingHalfExpiresOnce() {
        let job = Self.job(1)
        #expect(job.record(.main, .image(Self.buffer())) == nil)
        guard case .expired(let missing)? = job.expire() else {
            Issue.record("expected expiry")
            return
        }
        #expect(missing == [.aux])
        #expect(job.expire() == nil && job.record(.aux, .image(Self.buffer())) == nil)
        // Single420 completes with its main picture alone.
        guard case .decoded(_?, nil)? = Self.job(2, dual: false).record(.main, .image(Self.buffer())) else {
            Issue.record("Single420 completes with main")
            return
        }
    }

    @Test func racingHalvesAndDeadlinesSettleEachJobOnce() async {
        let jobs = (0..<2000).map { Self.job(UInt64($0)) }
        let settled = OSAllocatedUnfairLock(initialState: [Int](repeating: 0, count: jobs.count))
        let picture = SharedTestPicture(buffer: Self.buffer())
        await withTaskGroup(of: Void.self) { group in
            for (index, job) in jobs.enumerated() {
                for action in 0..<3 {
                    group.addTask {
                        let outcome: FrameJob.Outcome? =
                            switch action {
                            case 0: job.record(.main, .image(picture.buffer))
                            case 1: job.record(.aux, index % 5 == 0 ? .failed(-1) : .image(picture.buffer))
                            default: job.expire()
                            }
                        if outcome != nil { settled.withLock { $0[index] += 1 } }
                    }
                }
            }
        }
        #expect(settled.withLock { $0 }.allSatisfy { $0 == 1 })
    }
}

/// The stress test shares this immutable buffer across child tasks. A wrapper
/// makes that ownership explicit for Swift 6.1's sending-closure checking.
private struct SharedTestPicture: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}
